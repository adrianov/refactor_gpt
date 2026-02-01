# frozen_string_literal: true

# Gemini API client wrapper for ask_gpt and superagent (streaming, session context).
class AskGeminiClient
  include AskClientInstructions

  DEFAULT_MODEL = "gemini-3-flash"

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

  def build_system_message(style, brevity)
    {role: "user", content: build_system_instruction(style, brevity)}
  end

  def ask(messages, json: false, title: nil)
    @client.ask(messages, json: json, title: title)
  end

  def stream_answer(messages, &block)
    @client.stream_answer(messages, &block)
  end

  def chat(question, style: nil, brevity: nil)
    ask([{role: "user", content: build_system_instruction(style, brevity)},
      {role: "user", content: question}])
  end
end
