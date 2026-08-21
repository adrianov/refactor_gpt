# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/loader'

# OpenRouter answer extraction must tolerate non-chat JSON without crashing.
class TestOpenrouterClient < Minitest::Test
  def client
    OpenrouterClient.new(api_key: 'test-key', debug: false)
  end

  def response_with(body, status: 200)
    Object.new.tap do |resp|
      resp.define_singleton_method(:status) { status }
      resp.define_singleton_method(:body) { body }
    end
  end

  def test_extract_answer_returns_content
    resp = response_with('{"choices":[{"message":{"content":"hello"}}]}')
    assert_equal 'hello', client.send(:extract_answer, resp)
  end

  def test_extract_answer_uses_reasoning_when_content_null
    body = '{"choices":[{"message":{"content":null,"reasoning":"from thinking"}}]}'
    assert_equal 'from thinking', client.send(:extract_answer, response_with(body))
  end

  def test_extract_answer_exits_on_null_body
    resp = response_with('null')
    out, err = capture_io { assert_raises(SystemExit) { client.send(:extract_answer, resp) } }
    assert_empty out
    assert_includes err, 'No answer returned from OpenRouter API.'
  end

  def test_extract_answer_exits_on_missing_choices
    resp = response_with('{"id":"x","error":{"message":"weird"}}')
    _out, err = capture_io do
      assert_raises(SystemExit) { client.send(:extract_answer, resp) }
    end
    assert_includes err, 'No answer returned from OpenRouter API.'
  end

  def test_ask_propagates_unexpected_errors
    c = client
    c.define_singleton_method(:make_request_with_debug) { |*| raise NoMethodError, "dig for nil" }
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
    headers = client.send(:request_headers)
    assert_equal 'https://github.com/adrianov/refactor_gpt', headers['HTTP-Referer']
    assert_equal 'RefactorGPT', headers['X-OpenRouter-Title']
    assert_equal 'cli-agent', headers['X-OpenRouter-Categories']
  end

  def test_openrouter_headers_only_for_openrouter_hosts
    assert OpenrouterHeaders.openrouter_host?('https://openrouter.ai/api/v1')
    refute OpenrouterHeaders.openrouter_host?('https://api.openai.com/v1')
    assert_empty OpenrouterHeaders.for_base_url('https://api.openai.com/v1')
  end

  def test_build_request_body_includes_reasoning_when_set
    c = OpenrouterClient.new(api_key: 'test-key', reasoning: { effort: 'low' })
    body = c.send(:build_request_body, [{ role: 'user', content: 'hi' }])
    assert_equal({ effort: 'low' }, body[:reasoning])
  end

  def test_build_request_body_omits_reasoning_by_default
    body = client.send(:build_request_body, [{ role: 'user', content: 'hi' }])
    refute body.key?(:reasoning)
  end

  def test_commit_plan_client_uses_low_reasoning
    inner = CommitPlanClient.new(debug: false, progress: false).instance_variable_get(:@client)
    body = inner.send(:build_request_body, [{ role: 'user', content: 'hi' }])
    assert_equal({ effort: 'low' }, body[:reasoning])
  end
end
