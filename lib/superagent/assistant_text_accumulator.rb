# frozen_string_literal: true

require_relative 'stream_filter'

# Accumulates assistant text from parsed stream lines for full agent output (verification, etc.).
class AssistantTextAccumulator
  def accumulate(parsed, current_output)
    return current_output unless accumulatable?(parsed)

    stripped = StreamFilter.strip_trailing_think_close(parsed[:text])
    return current_output if stripped.to_s.strip.empty?

    (current_output || '') + stripped.to_s + "\n"
  end

  private

  def accumulatable?(parsed)
    text = parsed[:text]
    return false unless text && !text.to_s.empty?
    return false unless parsed[:type].nil? || parsed[:type].to_s == 'assistant'
    return false if parsed[:think_close_only]

    true
  end
end
