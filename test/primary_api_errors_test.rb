# frozen_string_literal: true

require 'ruby_llm'
require_relative '../lib/loader'

require 'minitest/autorun'
# Tests PrimaryApiErrors' error-payload helpers: body extraction, pretty formatting,
# and OpenRouter 400-wrapped upstream 429 detection.
class TestPrimaryApiErrors < Minitest::Test
  UPSTREAM_429_BODY = '{"error":{"message":"Rate limit exceeded","code":429}}'
  PREVIOUS_ERRORS_429 = '{"error":{"metadata":{"previous_errors":[{"code":429}]}}}'
  USAGE_LIMIT_BODY = '{"error":{"message":"Usage limit reached for 5 hour. ' \
    'Your limit will reset at 2026-09-14 23:16:44","code":429}}'

  def errors
    @errors ||= Object.new.extend(PrimaryApiErrors)
  end

  def test_error_body_reads_response_payload
    response = Object.new.tap { |resp| resp.define_singleton_method(:body) { UPSTREAM_429_BODY } }
    assert_equal UPSTREAM_429_BODY,
                 errors.send(:error_body, Object.new.tap { |e| e.define_singleton_method(:response) { response } })
    assert_empty errors.send(:error_body, nil)
  end

  def test_format_body_pretty_prints_json_and_keeps_plain_text
    assert_equal "{\n  \"a\":1\n}\n", errors.send(:format_body, '{"a":1}')
    assert_equal 'plain text', errors.send(:format_body, 'plain text')
    assert_equal '', errors.send(:format_body, '')
  end

  def test_upstream_rate_limited_variants
    [UPSTREAM_429_BODY, PREVIOUS_ERRORS_429, 'temporarily rate-limited upstream'].each do |body|
      assert errors.send(:upstream_rate_limited?, body), body.to_s[0, 40]
    end
    ['{"error":{"message":"bad request","code":400}}', '', nil].each do |body|
      refute errors.send(:upstream_rate_limited?, body), body.to_s[0, 40]
    end
  end

  def fake_bad_request(body)
    RubyLLM::BadRequestError.new(
      Object.new.tap { |resp| resp.define_singleton_method(:body) { body } }, 'Provider returned error'
    )
  end

  def fake_response(status, body)
    Struct.new(:status, :body).new(status, body)
  end

  def retrying_client
    client = OpenrouterClient.allocate
    client.define_singleton_method(:sleep) { |_| nil }
    client.define_singleton_method(:primary_api_error_endpoint) { 'https://openrouter.ai/api/v1/chat/completions' }
    client
  end

  def test_http_400_with_upstream_429_is_retried_manually
    attempts = 0
    _out, _err = capture_io do
      assert_equal :done, retrying_client.send(:complete_with_upstream_retries) {
        attempts += 1
        raise fake_bad_request(UPSTREAM_429_BODY) if attempts < 3

        :done
      }
    end
    assert_equal 3, attempts
  end

  def test_persistent_upstream_429_gives_up_after_three_retries
    _out, err = capture_io do
      assert_raises(RubyLLM::BadRequestError) do
        retrying_client.send(:complete_with_upstream_retries) { raise fake_bad_request(UPSTREAM_429_BODY) }
      end
    end
    assert_equal %w[1/3 2/3 3/3], err.scan(%r{\((\d/3)\)}).flatten
    assert_includes err, 'retrying in 30s'
  end

  def test_plain_400_propagates_without_retry
    client = retrying_client
    client.define_singleton_method(:sleep) { |secs| flunk("should not sleep #{secs}") }
    assert_raises(RubyLLM::BadRequestError) do
      client.send(:complete_with_upstream_retries) { raise fake_bad_request('{"error":{"code":400}}') }
    end
  end

  def test_plain_400_exits_with_provider_body
    _out, err = capture_io do
      assert_equal 1, assert_raises(SystemExit) {
        retrying_client.send(:translate_api_errors) do
          raise fake_bad_request('{"error":{"message":"This models maximum context length is exceeded"}}')
        end
      }.status
    end
    assert_includes err, 'rejected the request'
    assert_includes err, 'maximum context length'
  end

  def test_usage_limit_429_surfaces_as_unretryable_error_class
    UsageLimitCompat.apply
    error = assert_raises(UsageLimitCompat::UsageLimitError) do
      RubyLLM::ErrorMiddleware.parse_error(provider: nil, response: fake_response(429, USAGE_LIMIT_BODY))
    end
    assert_includes error.message, 'limit will reset at 2026-09-14 23:16:44'
    # The transport retry list matches RubyLLM::RateLimitError by ancestry; staying outside it
    # is what keeps usage-limit failures from being retried three times before surfacing.
    refute_kind_of RubyLLM::RateLimitError, error
  end

  def test_usage_limit_wrapped_in_http_400_also_surfaces_unretried
    UsageLimitCompat.apply
    assert_raises(UsageLimitCompat::UsageLimitError) do
      RubyLLM::ErrorMiddleware.parse_error(provider: nil, response: fake_response(400, USAGE_LIMIT_BODY))
    end
  end

  def test_transient_rate_limit_still_maps_to_rate_limit_error
    UsageLimitCompat.apply
    assert_raises(RubyLLM::RateLimitError) do
      RubyLLM::ErrorMiddleware.parse_error(provider: nil, response: fake_response(429, UPSTREAM_429_BODY))
    end
  end

  def usage_limit_response
    Struct.new(:status, :body, :headers).new(
      429,
      '{"error":{"message":"Usage limit reached for 5 hour. ' \
        'Your limit will reset at 2026-09-15 04:29:17","code":429}}',
      { 'retry-after-ms' => '600000' }
    )
  end

  def test_usage_limit_error_displays_reset_from_retry_after
    _out, err = capture_io do
      assert_equal 1, assert_raises(SystemExit) {
        retrying_client.send(:translate_api_errors) do
          raise UsageLimitCompat::UsageLimitError.new(usage_limit_response,
            'Usage limit reached for 5 hour. Your limit will reset at 2026-09-15 04:29:17')
        end
      }.status
    end
    headline = err.lines.first
    assert_includes headline, 'Unrecoverable provider usage limit'
    assert_match(/will reset at \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \(10m from now, per retry-after\)/, headline)
    refute_includes headline, '04:29:17'
  end

  def test_usage_limit_error_without_retry_after_keeps_provider_message
    _out, err = capture_io do
      assert_equal 1, assert_raises(SystemExit) {
        retrying_client.send(:translate_api_errors) do
          raise UsageLimitCompat::UsageLimitError.new(nil,
            'Usage limit reached for 5 hour. Your limit will reset at 2026-09-14 23:16:44')
        end
      }.status
    end
    assert_includes err.lines.first, 'Unrecoverable provider usage limit'
    assert_includes err.lines.first, 'will reset at 2026-09-14 23:16:44'
  end

  def test_transport_errors_exit_with_network_message
    _out, err = capture_io do
      assert_equal 1, assert_raises(SystemExit) {
        retrying_client.send(:translate_api_errors) { raise Errno::ECONNRESET }
      }.status
    end
    assert_includes err, 'Network/resource error'
  end

end
