# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/loader'

# Balance/1113 → BalanceError (no retry) → OpenRouter when configured.
class TestPrimaryApiBalanceError < Minitest::Test
  BALANCE_MSG = 'Insufficient balance or no resource package. Please recharge.'
  BALANCE_BODY = '{"error":{"code":"1113","message":"Insufficient balance or no resource package. Please recharge."}}'

  def client_with_fallback(answer: 'from-openrouter')
    client = OpenAiClient.allocate
    openrouter = Object.new
    openrouter.define_singleton_method(:configured?) { true }
    openrouter.define_singleton_method(:ask) { |*| answer }
    client.instance_variable_set(:@openrouter_client, openrouter)
    client.instance_variable_set(:@max_completion_tokens, nil)
    client.instance_variable_set(:@model, 'test-model')
    client.instance_variable_set(:@last_payload_bytes, nil)
    client
  end

  def test_balance_exhausted_detects_message_and_code
    client = OpenAiClient.allocate
    assert client.send(:balance_exhausted?, BALANCE_MSG, nil)
    assert client.send(:balance_exhausted?, nil, BALANCE_BODY)
    refute client.send(:balance_exhausted?, 'Rate limit exceeded', '{"error":{"code":"429"}}')
  end

  def test_raise_or_exit_raises_balance_error_when_fallback_configured
    client = client_with_fallback
    err = assert_raises(BalanceError) do
      client.send(:raise_or_exit_balance_error, 429, "Primary API balance exhausted: #{BALANCE_MSG}", BALANCE_BODY)
    end
    assert_includes err.message, 'Insufficient balance'
    assert_equal 429, err.status
  end

  def test_gemini_balance_raises_balance_error_when_fallback_configured
    client = GeminiClient.allocate
    client.instance_variable_set(:@openrouter_client, Object.new.tap { |o| def o.configured? = true })
    err = assert_raises(BalanceError) do
      client.send(:raise_or_exit_balance_error, 429, "Primary API balance exhausted: #{BALANCE_MSG}", BALANCE_BODY)
    end
    assert_includes err.message, 'Insufficient balance'
  end

  def test_balance_error_is_not_retried
    client = client_with_fallback
    calls = 0
    assert_raises(BalanceError) do
      client.send(:retry_with_backoff, max_retries: 3, base_delay: 0) do
        calls += 1
        raise BalanceError.new(BALANCE_MSG, status: 429, raw_body: BALANCE_BODY)
      end
    end
    assert_equal 1, calls
  end

  def test_openrouter_fallback_returns_answer_on_balance_error
    client = client_with_fallback(answer: 'openrouter-ok')
    result = client.send(:with_openrouter_fallback, [{role: 'user', content: 'hi'}]) do
      raise BalanceError.new(BALANCE_MSG, status: 429, raw_body: BALANCE_BODY)
    end
    assert_equal 'openrouter-ok', result
  end
end
