# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/loader'

# GeminiContentStream maps OpenAI-style messages onto generateContent shapes.
class TestGeminiContentStream < Minitest::Test
  def test_system_messages_become_system_instruction
    stream = GeminiContentStream.new
    body = stream.build_body([
      {role: 'system', content: 'Be brief.'},
      {role: 'user', content: 'Hi'},
      {role: 'assistant', content: 'Hello'},
      {role: 'user', content: 'Again'}
    ])

    assert_equal 'Be brief.', body.dig(:systemInstruction, :parts, 0, :text)
    assert_equal(
      [
        {role: 'user', parts: [{text: 'Hi'}]},
        {role: 'model', parts: [{text: 'Hello'}]},
        {role: 'user', parts: [{text: 'Again'}]}
      ],
      body[:contents]
    )
  end

  def test_omits_system_instruction_when_absent
    stream = GeminiContentStream.new
    body = stream.build_body([{role: 'user', content: 'Hi'}])
    refute body.key?(:systemInstruction)
    assert_equal [{role: 'user', parts: [{text: 'Hi'}]}], body[:contents]
  end

  def test_ask_gemini_prepared_messages_map_system_role
    prepared = AskGeminiClient.allocate.prepare_ask_messages([
      {role: 'system', content: 'Be brief.'},
      {role: 'user', content: 'Hi'}
    ])
    body = GeminiContentStream.new.build_body(prepared)
    assert_gemini_system_mapped(body, 'Be brief.', 'Hi')
  end

  def assert_gemini_system_mapped(body, system_text, user_snippet)
    assert_equal system_text, body.dig(:systemInstruction, :parts, 0, :text)
    assert_equal 'user', body[:contents].first[:role]
    assert_includes body[:contents].first[:parts].first[:text], user_snippet
    refute(body[:contents].any? { |c| c[:role] == 'system' })
  end

  def test_each_text_chunk_retains_partial_sse_frames
    stream = GeminiContentStream.new
    pieces = ['data: {"candidates":[{"content":{"parts":[{"text":"hel', "lo\"}]}}]}\n"]
    body = Object.new
    body.define_singleton_method(:each) { |&blk| pieces.each(&blk) }
    response = Object.new
    response.define_singleton_method(:body) { body }

    texts = []
    stream.each_text_chunk(response) { |text| texts << text }
    assert_equal ['hello'], texts
  end

  def test_assemble_accepts_json_array_without_sse
    stream = GeminiContentStream.new
    response = Struct.new(:status, :body).new(
      200,
      '[{"candidates":[{"content":{"parts":[{"text":"hi"}]}}]}]'
    )
    assembled = stream.assemble(response)
    assert_includes assembled.body, '"text":"hi"'
  end
end
