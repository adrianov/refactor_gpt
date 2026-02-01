# frozen_string_literal: true

# OpenAI API client wrapper (OpenAI and Claude backends via LlmRouter) for ask_gpt and superagent.
class AskGptClient
  include AskClientInstructions

  SEARCH_MODEL = "gpt-4o-search-preview"

  attr_reader :model, :backend

  def initialize(model: nil, max_completion_tokens: nil, debug: false, api_base_url: nil, api_key: nil, backend: nil)
    @model = model
    @backend = backend || :openai
    @max_completion_tokens = max_completion_tokens
    @debug = debug
    @client = OpenAiClient.new(model: model, max_completion_tokens: max_completion_tokens, debug: debug,
      progress_title: "Thinking", api_base_url: api_base_url, api_key: api_key)
  end

  def build_system_message(style, brevity)
    {role: "system", content: build_system_instruction(style, brevity)}
  end

  def change_model(new_model)
    return if @model == new_model

    env = ENV.to_h.merge(Utility.load_env_vars)
    config = LlmRouter.config_for_model(new_model, env)
    return if config.nil?

    @model = new_model
    @backend = config[:backend]
    @client = OpenAiClient.new(model: @model, max_completion_tokens: @max_completion_tokens, debug: @debug,
      progress_title: "Thinking", api_base_url: config[:base_url], api_key: config[:access_token])
  end

  def search_mode?
    @model == SEARCH_MODEL
  end

  def enable_search_mode
    change_model(SEARCH_MODEL)
  end

  def disable_search_mode
    change_model(nil)
  end

  def chat(question, style: nil, brevity: nil)
    ask([{role: "system", content: build_system_instruction(style, brevity)},
      {role: "user", content: question}])
  end

  def ask(messages, json: false, title: nil)
    @client.ask(messages, json: json, title: title)
  end
end
