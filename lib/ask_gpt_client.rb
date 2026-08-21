# frozen_string_literal: true

# OpenRouter client wrapper for ask_gpt and superagent.
class AskGptClient
  include AskClientInstructions

  attr_reader :model

  def initialize(model: nil, max_completion_tokens: nil, debug: false)
    @model = model
    @client = OpenrouterClient.new(model: model, max_completion_tokens: max_completion_tokens,
      debug: debug, progress_title: "Thinking")
  end
end
