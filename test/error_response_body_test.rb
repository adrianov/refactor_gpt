# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/loader'

# OpenRouter may wrap upstream 429s as HTTP 400 with previous_errors metadata.
class TestErrorResponseBody < Minitest::Test
  # Realistic OpenRouter payload (phrase + previous_errors).
  UPSTREAM_429_BODY = <<~JSON.chomp
    {"error":{"message":"Provider returned error","code":400,"metadata":{"provider_error_code":"400","previous_errors":[{"code":429,"message":"Provider returned error","provider_name":"Google AI Studio","raw":"google/gemini-3.7-flash is temporarily rate-limited upstream. Please retry shortly"}]}}}
  JSON

  # Structural 429 only — no "rate-limited upstream" phrase.
  PREVIOUS_ERRORS_429 = <<~JSON.chomp
    {"error":{"message":"Provider returned error","code":400,"metadata":{"previous_errors":[{"code":429,"message":"Too Many Requests","provider_name":"Google"}]}}}
  JSON

  def response_with(body, status:)
    Object.new.tap do |resp|
      resp.define_singleton_method(:status) { status }
      resp.define_singleton_method(:body) { body }
      resp.define_singleton_method(:headers) { {} }
    end
  end

  def test_upstream_rate_limited_from_previous_errors_without_phrase
    assert ErrorResponseBody.upstream_rate_limited?(PREVIOUS_ERRORS_429)
  end

  def test_upstream_rate_limited_from_error_code
    assert ErrorResponseBody.upstream_rate_limited?('{"error":{"code":429,"message":"Rate limit"}}')
  end

  def test_upstream_rate_limited_from_raw_phrase
    assert ErrorResponseBody.upstream_rate_limited?('temporarily rate-limited upstream')
  end

  def test_upstream_rate_limited_false_for_plain_400
    refute ErrorResponseBody.upstream_rate_limited?('{"error":{"message":"bad request","code":400}}')
  end

  def test_http_400_with_upstream_429_raises_rate_limit_error
    client = OpenrouterClient.allocate
    err = assert_raises(RateLimitError) do
      client.send(:handle_non_success_status, response_with(UPSTREAM_429_BODY, status: 400))
    end
    assert_includes err.message, 'Rate limited'
    assert_includes err.raw_body, 'previous_errors'
  end

  def test_openrouter_client_flags_upstream_rate_limit_body_as_rate_limited
    client = OpenrouterClient.allocate
    assert_raises(RateLimitError) do
      client.send(:handle_non_success_status, response_with(UPSTREAM_429_BODY, status: 400))
    end
    refute ErrorResponseBody.upstream_rate_limited?('{"error":{"code":400}}')
  end
end
