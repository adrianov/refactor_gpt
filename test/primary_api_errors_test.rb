# frozen_string_literal: true

require 'ruby_llm'
require_relative '../lib/loader'

# Tests PrimaryApiErrors' error-payload helpers: body extraction, pretty formatting,
# and OpenRouter 400-wrapped upstream 429 detection.
class TestPrimaryApiErrors < Minitest::Test
  UPSTREAM_429_BODY = '{"error":{"message":"Rate limit exceeded","code":429}}'
  PREVIOUS_ERRORS_429 = '{"error":{"metadata":{"previous_errors":[{"code":429}]}}}'

  def errors
    @errors ||= Object.new.extend(PrimaryApiErrors)
  end

  def test_error_body_reads_response_payload
    response = Object.new.tap { |resp| resp.define_singleton_method(:body) { UPSTREAM_429_BODY } }
    error = Object.new.tap { |err| err.define_singleton_method(:response) { response } }
    assert_equal UPSTREAM_429_BODY, errors.send(:error_body, error)
    assert_empty errors.send(:error_body, nil)
  end

  def test_format_body_pretty_prints_json_and_keeps_plain_text
    assert_equal "{\n  \"a\":1\n}\n", errors.send(:format_body, '{"a":1}')
    assert_equal 'plain text', errors.send(:format_body, 'plain text')
    assert_equal '', errors.send(:format_body, '')
  end

  def test_upstream_rate_limited_variants
    positives = [UPSTREAM_429_BODY, PREVIOUS_ERRORS_429, 'temporarily rate-limited upstream']
    negatives = ['{"error":{"message":"bad request","code":400}}', '', nil]
    positives.each { |body| assert errors.send(:upstream_rate_limited?, body), body.to_s[0, 40] }
    negatives.each { |body| refute errors.send(:upstream_rate_limited?, body), body.to_s[0, 40] }
  end

  def fake_bad_request(body)
    response = Object.new.tap { |resp| resp.define_singleton_method(:body) { body } }
    RubyLLM::BadRequestError.new(response, 'Provider returned error')
  end

  def retrying_client
    client = OpenrouterClient.allocate
    client.define_singleton_method(:sleep) { |_| nil }
    client.define_singleton_method(:primary_api_error_endpoint) { 'https://openrouter.ai/api/v1/chat/completions' }
    client
  end

  def test_http_400_with_upstream_429_is_retried_manually
    attempts = 0
    outcome = nil
    _out, _err = capture_io do
      outcome = retrying_client.send(:complete_with_upstream_retries) do
        attempts += 1
        raise fake_bad_request(UPSTREAM_429_BODY) if attempts < 3

        :done
      end
    end
    assert_equal 3, attempts
    assert_equal :done, outcome
  end

  def test_plain_400_propagates_without_retry
    client = retrying_client
    client.define_singleton_method(:sleep) { |secs| flunk("should not sleep #{secs}") }
    assert_raises(RubyLLM::BadRequestError) do
      client.send(:complete_with_upstream_retries) { raise fake_bad_request('{"error":{"code":400}}') }
    end
  end

end
