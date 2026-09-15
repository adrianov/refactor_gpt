# frozen_string_literal: true

require 'ruby_llm'
require 'minitest/autorun'
require_relative '../lib/loader'

# Client wiring on ruby-llm: answer extraction, JSON fallback, attribution headers,
# reasoning passthrough, and unexpected-error propagation.
class TestOpenrouterClient < Minitest::Test
  def client
    OpenrouterClient.new(api_key: 'test-key', debug: false)
  end

  def assistant_message(content:, thinking_text: nil)
    RubyLLM::Message.new(
      role: :assistant, content: content,
      thinking: thinking_text && RubyLLM::Thinking.new(text: thinking_text)
    )
  end

  def test_answer_from_returns_content
    assert_equal 'hello', client.send(:answer_from, assistant_message(content: 'hello'))
  end

  def test_answer_from_uses_thinking_when_content_blank
    assert_equal 'from thinking', 
client.send(:answer_from, assistant_message(content: nil, thinking_text: 'from thinking'))
  end

  def test_ensure_answer_exits_on_empty
    out, err = capture_io do
      assert_raises(SystemExit) { client.send(:ensure_answer!, '', assistant_message(content: nil)) }
    end
    assert_empty out
    assert_includes err, 'No answer returned from OpenRouter API.'
  end

  def test_ask_propagates_unexpected_errors
    c = client
    c.define_singleton_method(:build_chat) { |*| raise NoMethodError, 'dig for nil' }
    assert_raises(NoMethodError) { c.ask([{role: 'user', content: 'hi'}]) }
  end

  def test_openrouter_json_extracts_fenced_object
    text = "Sure:\n```json\n{\"a\":1}\n```\n"
    assert_equal '{"a":1}', OpenrouterJson.extract_from_text(text)
  end

  def test_openrouter_json_extracts_json_prefixed_fence
    text = "json```json\n{\"a\":1}\n```"
    assert_equal '{"a":1}', OpenrouterJson.extract_from_text(text)
  end

  def test_openrouter_json_ignores_braces_inside_strings
    text = 'prefix {"a":"use } here","b":2} suffix'
    assert_equal '{"a":"use } here","b":2}', OpenrouterJson.extract_from_text(text)
  end

  def test_openrouter_json_prefers_later_complete_object
    text = '{ "partial": [ { "x": 1 } Let me redo {"a":1,"b":2}'
    assert_equal '{"a":1,"b":2}', OpenrouterJson.extract_from_text(text)
  end

  def test_request_headers_include_app_attribution
    chat = OpenrouterClient.new(api_key: 'test-key', api_base_url: 'https://openrouter.ai/api/v1')
           .send(:build_chat, [{role: 'user', content: 'hi'}])
    assert_equal 'https://github.com/adrianov/refactor_gpt', chat.headers['HTTP-Referer']
    assert_equal 'RefactorGPT', chat.headers['X-Title']
  end

  def test_openrouter_headers_only_for_openrouter_hosts
    assert OpenrouterHeaders.openrouter_host?('https://openrouter.ai/api/v1')
    refute OpenrouterHeaders.openrouter_host?('https://api.openai.com/v1')
    assert_empty OpenrouterHeaders.for_base_url('https://api.openai.com/v1')
  end

  def test_build_chat_includes_reasoning_when_set
    c = OpenrouterClient.new(api_key: 'test-key', reasoning: { effort: 'low' })
    thinking = c.send(:build_chat, [{role: 'user', content: 'hi'}]).instance_variable_get(:@thinking)
    assert_equal 'low', thinking.effort
  end

  def test_build_chat_omits_reasoning_by_default
    refute client.send(:build_chat, [{role: 'user', content: 'hi'}]).instance_variable_get(:@thinking)
  end

  def test_commit_plan_client_uses_low_reasoning
    inner = CommitPlanClient.new(debug: false, progress: false).instance_variable_get(:@client)
    thinking = inner.send(:build_chat, [{role: 'user', content: 'hi'}]).instance_variable_get(:@thinking)

    assert_equal 'low', thinking.effort
  end

  def test_model_normalization_strips_openrouter_routing_prefix
    assert_equal 'stealth/ox-alpha',
      OpenrouterClient.new(model: 'openrouter/stealth/ox-alpha', api_key: 'test-key').model
  end

  def test_model_normalization_keeps_vendor_slugs_and_defaults
    unprefixed = OpenrouterClient.new(model: 'google/gemini-3.7-flash', api_key: 'test-key')
    assert_equal 'google/gemini-3.7-flash', unprefixed.model
    assert_equal OpenrouterClient::DEFAULT_MODEL,
      Class.new(OpenrouterClient) { def load_env_vars(*); {}; end }.new(api_key: 'test-key').model
  end

  def test_fallback_connection_loads_from_env
    fallback = Class.new(OpenrouterClient) do
      def load_env_vars(*)
        { 'API_KEY_2' => 'k2', 'BASE_URL_2' => 'https://x.example/v1', 'MODEL_2' => 'vendor/m2' }
      end
    end.new(api_key: 'test-key').instance_variable_get(:@fallback)
    assert_equal 'k2', fallback[:api_key]
    assert_equal 'https://x.example/v1', fallback[:api_base_url]
    assert_equal 'vendor/m2', fallback[:model]
  end

  def test_fallback_connection_absent_without_api_key_2
    assert_nil Class.new(OpenrouterClient) { def load_env_vars(*); {}; end }
      .new(api_key: 'test-key').instance_variable_get(:@fallback)
  end

end
