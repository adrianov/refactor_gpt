# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/loader'

# PromptCache adds Anthropic/Qwen breakpoints and sticky prompt_cache_key only when supported.
class TestPromptCache < Minitest::Test
  OPENROUTER = 'https://openrouter.ai/api/v1'
  OPENAI = 'https://api.openai.com/v1'
  OTHER = 'https://api.example.com/v1'
  SYSTEM = 'Be a concise Ruby assistant.'

  def messages(system: SYSTEM, user: 'Hi')
    [{role: 'system', content: system}, {role: 'user', content: user}]
  end

  def apply(model:, base_url:, msgs: nil)
    body = {model: model, messages: (msgs || messages).map(&:dup)}
    PromptCache.apply!(body, model: model, base_url: base_url)
    body
  end

  def test_skips_when_system_prompt_is_blank
    [apply(model: 'anthropic/claude-sonnet-4', base_url: OPENROUTER, msgs: [{role: 'user', content: 'hi'}]),
     apply(model: 'anthropic/claude-sonnet-4', base_url: OPENROUTER,
       msgs: [{role: 'system', content: ''}, {role: 'user', content: 'hi'}]),
     apply(model: 'anthropic/claude-sonnet-4', base_url: OPENROUTER,
       msgs: [{role: 'system', content: '  '}, {role: 'user', content: 'hi'}])].each do |body|
      refute body.key?(:cache_control)
      refute body.key?(:prompt_cache_key)
      sys = body[:messages].find { |m| m[:role] == 'system' }
      refute_instance_of Array, sys[:content] if sys
    end
  end

  def test_openrouter_anthropic_wraps_system_and_sets_key
    body = apply(model: 'anthropic/claude-sonnet-4', base_url: OPENROUTER)
    assert_equal({type: 'ephemeral'}, body[:cache_control])
    assert_equal PromptCache.cache_key(SYSTEM), body[:prompt_cache_key]
    assert_equal(
      [{type: 'text', text: SYSTEM, cache_control: {type: 'ephemeral'}}],
      body[:messages].find { |m| m[:role] == 'system' }[:content]
    )
  end

  def test_prompt_cache_key_stable_for_same_system_not_user_text
    a = apply(model: 'openrouter/anthropic/claude-sonnet-4', base_url: OPENROUTER, msgs: messages(user: 'A'))
    b = apply(model: 'openrouter/~anthropic/claude-haiku-latest', base_url: OPENROUTER, msgs: messages(user: 'B'))
    c = apply(model: 'anthropic/claude-sonnet-4', base_url: OPENROUTER, msgs: messages(system: 'Other', user: 'A'))
    assert_equal a[:prompt_cache_key], b[:prompt_cache_key]
    refute_equal a[:prompt_cache_key], c[:prompt_cache_key]
  end

  def test_openrouter_qwen_uses_explicit_breakpoints
    body = apply(model: 'qwen/qwen3-32b', base_url: OPENROUTER)
    assert_equal({type: 'ephemeral'}, body[:cache_control])
    assert body[:prompt_cache_key]
  end

  def test_openrouter_auto_gets_key_without_cache_control
    body = apply(model: 'openrouter/auto', base_url: OPENROUTER)
    refute body.key?(:cache_control)
    assert_equal PromptCache.cache_key(SYSTEM), body[:prompt_cache_key]
    assert_equal SYSTEM, body[:messages].find { |m| m[:role] == 'system' }[:content]
  end

  def test_openai_host_gets_no_cache_fields
    body = apply(model: 'gpt-5-nano', base_url: OPENAI)
    refute body.key?(:cache_control)
    refute body.key?(:prompt_cache_key)
    assert_equal SYSTEM, body[:messages].find { |m| m[:role] == 'system' }[:content]
  end

  def test_unknown_host_gets_no_cache_fields
    body = apply(model: 'claude-sonnet-4-6', base_url: OTHER)
    refute body.key?(:cache_control)
    refute body.key?(:prompt_cache_key)
    assert_equal SYSTEM, body[:messages].find { |m| m[:role] == 'system' }[:content]
  end

  def test_does_not_mutate_original_system_message
    original = messages
    apply(model: 'anthropic/claude-sonnet-4', base_url: OPENROUTER, msgs: original)
    assert_equal SYSTEM, original.first[:content]
  end

  def test_openrouter_client_applies_cache_on_anthropic_model
    client = OpenrouterClient.new(api_key: 'test-key', model: 'anthropic/claude-sonnet-4')
    body = client.send(:build_request_body, messages)
    assert_equal({type: 'ephemeral'}, body[:cache_control])
    assert_equal PromptCache.cache_key(SYSTEM), body[:prompt_cache_key]
  end

  def test_openrouter_client_skips_explicit_cache_off_openrouter
    client = OpenrouterClient.new(
      api_key: 'test-key',
      api_base_url: 'https://api.anthropic.com/v1',
      model: 'claude-sonnet-4-6'
    )
    body = client.send(:build_request_body, messages)
    refute body.key?(:cache_control)
    refute body.key?(:prompt_cache_key)
  end

  def test_openai_client_skips_cache_on_openai_host
    client = OpenAiClient.allocate
    client.instance_variable_set(:@model, 'gpt-5-nano')
    client.instance_variable_set(:@api_base_url, OPENAI)
    client.instance_variable_set(:@max_completion_tokens, nil)
    body = client.send(:build_request_body, messages)
    refute body.key?(:cache_control)
    refute body.key?(:prompt_cache_key)
  end
end

class TestAskClientInstructions < Minitest::Test
  class Dummy
    include AskClientInstructions
  end

  def setup
    @client = Dummy.new
  end

  def test_system_instruction_omits_clock
    refute_includes @client.build_system_instruction(nil, nil), 'Current date/time'
  end

  def test_dates_last_user_without_mutating_original
    messages = [{role: 'system', content: 'sys'}, {role: 'user', content: 'Hi'}]
    dated = @client.prepare_ask_messages(messages)
    assert_equal 'Hi', messages.last[:content]
    assert_includes dated.last[:content], 'Current date/time:'
    assert_includes dated.last[:content], 'Hi'
    assert_equal 'sys', dated.first[:content]
    assert_equal 'system', dated.first[:role]
  end

  def test_promotes_leading_user_instruction_when_no_system
    messages = [{role: 'user', content: 'Be brief.'}, {role: 'user', content: 'Hi'}]
    prepared = @client.prepare_ask_messages(messages)
    assert_equal 'user', messages.first[:role]
    assert_equal 'system', prepared.first[:role]
    assert_equal 'Be brief.', prepared.first[:content]
    assert_includes prepared.last[:content], 'Hi'
  end

  def test_leaves_single_user_message_as_user
    messages = [{role: 'user', content: 'Hi'}]
    prepared = @client.prepare_ask_messages(messages)
    assert_equal 'user', prepared.first[:role]
    assert_includes prepared.first[:content], 'Hi'
  end
end
