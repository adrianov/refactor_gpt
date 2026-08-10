# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/loader'

# Balance/1113 must raise RateLimitError when OpenRouter fallback is configured (no hard exit).
class TestPrimaryApiBalanceError < Minitest::Test
  BALANCE_MSG = 'Insufficient balance or no resource package. Please recharge.'
  BALANCE_BODY = '{"error":{"code":"1113","message":"Insufficient balance or no resource package. Please recharge."}}'

  def client_with_fallback
    client = OpenAiClient.allocate
    client.instance_variable_set(:@openrouter_client, Object.new.tap do |o|
      def o.configured? = true
    end)
    client
  end

  def client_without_fallback
    client = OpenAiClient.allocate
    client.instance_variable_set(:@openrouter_client, nil)
    client
  end

  def test_balance_exhausted_detects_message_and_code
    client = OpenAiClient.allocate
    assert client.send(:balance_exhausted?, BALANCE_MSG, nil)
    assert client.send(:balance_exhausted?, nil, BALANCE_BODY)
    refute client.send(:balance_exhausted?, 'Rate limit exceeded', '{"error":{"code":"429"}}')
  end

  def test_raise_or_exit_raises_when_fallback_configured
    client = client_with_fallback
    err = assert_raises(RateLimitError) do
      client.send(:raise_or_exit_balance_error, 429, "Rate limited by API: #{BALANCE_MSG}", BALANCE_BODY)
    end
    assert_includes err.message, 'Insufficient balance'
  end

  def test_gemini_balance_raises_when_fallback_configured
    client = GeminiClient.allocate
    client.instance_variable_set(:@openrouter_client, Object.new.tap do |o|
      def o.configured? = true
    end)
    err = assert_raises(RateLimitError) do
      client.send(:raise_or_exit_balance_error, 429, "Rate limited by API: #{BALANCE_MSG}", BALANCE_BODY)
    end
    assert_includes err.message, 'Insufficient balance'
  end
end
