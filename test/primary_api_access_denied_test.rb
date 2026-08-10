# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/loader'

# HTTP 403 → AccessDeniedError → REFACTOR/OpenRouter alternate when configured.
class TestPrimaryApiAccessDenied < Minitest::Test
  DENIED_BODY = '{"success":false,"error":"Access denied by security policy."}'

  def response_403
    Object.new.tap do |resp|
      resp.define_singleton_method(:status) { 403 }
      resp.define_singleton_method(:body) { DENIED_BODY }
      resp.define_singleton_method(:headers) { {} }
    end
  end

  def client_with_refactor_fallback(answer: 'from-refactor')
    client = OpenAiClient.allocate
    client.instance_variable_set(:@api_base_url, 'https://openrouter.ai/api/v1')
    client.instance_variable_set(:@openrouter_client, Object.new.tap do |o|
      o.define_singleton_method(:configured?) { true }
      o.instance_variable_set(:@api_base_url, 'https://openrouter.ai/api/v1')
      o.define_singleton_method(:ask) { |*| nil }
    end)
    client.instance_variable_set(:@refactor_fallback_client, Object.new.tap do |o|
      o.define_singleton_method(:ask) { |*| answer }
    end)
    client.instance_variable_set(:@max_completion_tokens, nil)
    client.instance_variable_set(:@model, 'test-model')
    client.instance_variable_set(:@last_payload_bytes, nil)
    client
  end

  def test_403_raises_access_denied_when_fallback_configured
    client = client_with_refactor_fallback
    err = assert_raises(AccessDeniedError) do
      client.send(:handle_non_success_status, response_403)
    end
    assert_equal 403, err.status
    assert_includes err.message, 'Access denied'
  end

  def test_access_denied_falls_through_to_refactor_api
    client = client_with_refactor_fallback(answer: 'refactor-ok')
    result = client.send(:with_openrouter_fallback, [{role: 'user', content: 'hi'}]) do
      raise AccessDeniedError.new('denied', status: 403, raw_body: DENIED_BODY)
    end
    assert_equal 'refactor-ok', result
  end

  def test_openrouter_fallback_skipped_when_same_host_as_primary
    client = client_with_refactor_fallback
    refute client.send(:openrouter_fallback_usable?)
    assert client.send(:fallback_configured?)
  end
end
