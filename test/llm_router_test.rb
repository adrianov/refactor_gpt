# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/loader'

class TestLlmRouter < Minitest::Test
  def test_gemini_without_token_uses_openai
    env = {'OPENAI_ACCESS_TOKEN' => 'sk-test', 'OPENAI_BASE_URL' => 'https://openrouter.ai/api/v1'}
    cfg = LlmRouter.config_for_model('gemini-3.7-flash', env)
    assert_equal :openai, cfg[:backend]
    assert_equal 'gemini-3.7-flash', cfg[:model]
  end

  def test_gemini_with_token_stays_gemini
    env = {
      'GEMINI_ACCESS_TOKEN' => 'gk-test',
      'GEMINI_BASE_URL' => 'https://generativelanguage.googleapis.com/v1beta',
      'OPENAI_ACCESS_TOKEN' => 'sk-test'
    }
    assert_equal :gemini, LlmRouter.config_for_model('gemini-3.7-flash', env)[:backend]
  end

  def test_gemini_without_any_token_is_nil
    assert_nil LlmRouter.config_for_model('gemini-3.7-flash', {})
  end
end
