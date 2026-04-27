# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/loader'

# Tests provider error messages that should retry as transient network failures.
class TestPrimaryApiNetworkError < Minitest::Test
  NETWORK_ERROR = 'Network error, error id: 2026042716220695a71169ec76409d, please try again later'

  def test_openai_client_treats_provider_network_error_as_retryable
    assert OpenAiClient.allocate.send(:is_network_resource_error?, NETWORK_ERROR)
  end

  def test_gemini_client_treats_provider_network_error_as_retryable
    assert GeminiClient.allocate.send(:is_network_resource_error?, NETWORK_ERROR)
  end
end
