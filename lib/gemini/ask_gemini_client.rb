# frozen_string_literal: true

# Gemini API client wrapper for ask_gpt and superagent (streaming, session context).
# Uses shared AskClientInstructions (system role); GeminiContentStream maps system → systemInstruction.
class AskGeminiClient
  include AskClientInstructions

  attr_reader :model, :backend

  def initialize(model: nil, max_completion_tokens: nil, debug: false, progress: true, api_base_url: nil, api_key: nil)
    @model = model
    @backend = :gemini
    @max_completion_tokens = max_completion_tokens
    @debug = debug
    progress_title = progress ? "Thinking" : nil
    @client = GeminiClient.new(model: model, max_completion_tokens: max_completion_tokens, debug: debug,
      progress_title: progress_title, api_base_url: api_base_url, api_key: api_key)
  end

  def stream_answer(messages, &block)
    @client.stream_answer(prepare_ask_messages(messages), &block)
  end
end
