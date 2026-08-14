# frozen_string_literal: true

require 'oj'

# Reads assistant text from OpenAI-compatible chat.completion messages.
# Some hosts put the reply in reasoning when content is null.
module CompletionAnswer
  TEXT_KEYS = %w[content reasoning_content reasoning].freeze

  module_function

  def from_body(body)
    return nil if body.nil? || body.to_s.empty?

    parsed = Oj.load(body)
    return nil unless parsed.is_a?(Hash)

    from_message(parsed.dig('choices', 0, 'message'))
  end

  def from_message(message)
    return nil unless message.is_a?(Hash)

    TEXT_KEYS.each do |key|
      value = message[key]
      return value unless value.nil? || value.to_s.strip.empty?
    end
    nil
  end
end
