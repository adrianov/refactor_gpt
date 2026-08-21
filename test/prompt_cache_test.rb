# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/loader'

# PromptCache adds Anthropic/Qwen/Gemini/Auto breakpoints and sticky prompt_cache_key only when supported.
class TestPromptCache < Minitest::Test
  OPENROUTER = 'https://openrouter.ai/api/v1'
  OPENAI = 'https://api.openai.com/v1'
  OTHER = 'https://api.example.com/v1'
  SYSTEM = 'Be a concise Ruby assistant.'
  CACHE_BLOCKS = [{type: 'text', text: SYSTEM, cache_control: {type: 'ephemeral'}}].freeze

  def messages(system: SYSTEM, user: 'Hi')
    [{role: 'system', content: system}, {role: 'user', content: user}]
  end

  def params(model:, base_url:, msgs: nil, session_id: nil)
    PromptCache.request_params(msgs || messages, model: model, base_url: base_url, session_id: session_id)
  end

  def cached_system_content(model:, base_url:, msgs: nil)
    PromptCache.cached_messages(msgs || messages, model: model, base_url: base_url)
               .find { |m| m[:role] == 'system' }[:content]
  end

  def raw_blocks(content)
    assert_instance_of RubyLLM::Content::Raw, content
    content.value
  end

  def test_skips_when_system_prompt_is_blank
    blank_cases = [
      [{role: 'user', content: 'hi'}],
      [{role: 'system', content: ''}, {role: 'user', content: 'hi'}],
      [{role: 'system', content: '  '}, {role: 'user', content: 'hi'}]
    ]
    blank_cases.each do |msgs|
      assert_empty params(model: 'anthropic/claude-sonnet-4', base_url: OPENROUTER, msgs: msgs)
      assert_equal(
        msgs,
        PromptCache.cached_messages(msgs, model: 'anthropic/claude-sonnet-4', base_url: OPENROUTER)
      )
    end
  end

  def test_openrouter_anthropic_wraps_system_and_sets_key
    result = params(model: 'anthropic/claude-sonnet-4', base_url: OPENROUTER)
    assert_equal({type: 'ephemeral'}, result[:cache_control])
    assert_equal PromptCache.cache_key(SYSTEM), result[:prompt_cache_key]
    refute result.key?(:session_id)
    assert_equal CACHE_BLOCKS, 
raw_blocks(cached_system_content(model: 'anthropic/claude-sonnet-4', base_url: OPENROUTER))
  end

  def test_prompt_cache_key_stable_for_same_system_not_user_text
    a = params(model: 'openrouter/anthropic/claude-sonnet-4', base_url: OPENROUTER, msgs: messages(user: 'A'))
    b = params(model: 'openrouter/~anthropic/claude-haiku-latest', base_url: OPENROUTER, msgs: messages(user: 'B'))
    c = params(model: 'anthropic/claude-sonnet-4', base_url: OPENROUTER, msgs: messages(system: 'Other', user: 'A'))
    assert_equal a[:prompt_cache_key], b[:prompt_cache_key]
    refute_equal a[:prompt_cache_key], c[:prompt_cache_key]
  end

  def test_openrouter_qwen_uses_explicit_breakpoints
    result = params(model: 'qwen/qwen3-32b', base_url: OPENROUTER)
    assert_equal({type: 'ephemeral'}, result[:cache_control])
    assert result[:prompt_cache_key]
    refute result.key?(:session_id)
  end

  def test_openrouter_gemini_wraps_system_and_sets_key
    %w[google/gemini-3.7-flash gemini-3.7-flash openrouter/google/gemini-3.7-flash].each do |model|
      result = params(model: model, base_url: OPENROUTER)
      assert_equal({type: 'ephemeral'}, result[:cache_control], model)
      assert_equal PromptCache.cache_key(SYSTEM), result[:prompt_cache_key], model
      refute result.key?(:session_id)
      assert_equal CACHE_BLOCKS, raw_blocks(cached_system_content(model: model, base_url: OPENROUTER)), model
    end
  end

  def test_openrouter_auto_gets_cache_markers_and_session_id
    result = params(model: 'openrouter/auto', base_url: OPENROUTER)
    assert_equal({type: 'ephemeral'}, result[:cache_control])
    assert_equal PromptCache.cache_key(SYSTEM), result[:prompt_cache_key]
    assert_equal "refactor-#{Process.pid}", result[:session_id]
    assert_equal CACHE_BLOCKS, raw_blocks(cached_system_content(model: 'openrouter/auto', base_url: OPENROUTER))
  end

  def test_openrouter_auto_uses_explicit_session_id
    result = params(model: 'openrouter/auto', base_url: OPENROUTER, session_id: 'refactor-run-42')
    assert_equal 'refactor-run-42', result[:session_id]
  end

  def test_openrouter_other_model_gets_key_without_cache_control
    result = params(model: 'openai/gpt-4o-mini', base_url: OPENROUTER)
    refute result.key?(:cache_control)
    refute result.key?(:session_id)
    assert_equal PromptCache.cache_key(SYSTEM), result[:prompt_cache_key]
    assert_equal SYSTEM, cached_system_content(model: 'openai/gpt-4o-mini', base_url: OPENROUTER)
  end

  def test_non_openrouter_hosts_get_no_cache_fields
    [
      {model: 'gpt-5-nano', base_url: OPENAI},
      {model: 'claude-sonnet-4-6', base_url: OTHER}
    ].each do |case_data|
      assert_empty params(**case_data)
      assert_equal SYSTEM, cached_system_content(**case_data)
    end
  end

  def test_does_not_mutate_original_system_message
    original = messages
    PromptCache.cached_messages(original, model: 'anthropic/claude-sonnet-4', base_url: OPENROUTER)
    assert_equal SYSTEM, original.first[:content]
  end

  def cached_chat(model:, base_url: nil)
    kwargs = { api_key: 'test-key', model: model }
    kwargs[:api_base_url] = base_url if base_url
    OpenrouterClient.new(**kwargs).send(:build_chat, messages)
  end

  def system_content(chat)
    chat.messages.find { |m| m.role == :system }.content
  end

  def test_client_build_chat_applies_cache_on_anthropic_model
    chat = cached_chat(model: 'anthropic/claude-sonnet-4')
    assert_equal({type: 'ephemeral'}, chat.params[:cache_control])
    assert_equal PromptCache.cache_key(SYSTEM), chat.params[:prompt_cache_key]
    refute chat.params.key?(:session_id)
    assert_equal CACHE_BLOCKS, raw_blocks(system_content(chat))
  end

  def test_client_build_chat_applies_cache_on_auto_model
    chat = cached_chat(model: 'openrouter/auto')
    assert_equal({type: 'ephemeral'}, chat.params[:cache_control])
    assert_equal PromptCache.cache_key(SYSTEM), chat.params[:prompt_cache_key]
    assert_equal "refactor-#{Process.pid}", chat.params[:session_id]
  end

  def test_client_build_chat_skips_cache_off_openrouter_host
    chat = cached_chat(model: 'gpt-5-nano', base_url: OTHER)
    refute chat.params.key?(:cache_control)
    refute chat.params.key?(:prompt_cache_key)
    refute chat.params.key?(:session_id)
    assert_equal SYSTEM, system_content(chat)
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
