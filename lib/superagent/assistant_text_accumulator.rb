# frozen_string_literal: true

# Accumulates assistant text from parsed stream lines for full agent output (verification, etc.).
class AssistantTextAccumulator
  THINK_CLOSE_TAIL = /\s*`*\s*<\/think>\s*`*\s*\z/i

  def accumulate(parsed, current_output)
    return current_output unless accumulatable?(parsed)

    stripped = strip_trailing_think_close(parsed[:text])
    return current_output if stripped.nil? || stripped.to_s.empty?

    (current_output || '') + stripped.to_s + "\n"
  end

  private

  def strip_trailing_think_close(text)
    return text if text.nil? || text.to_s.empty?
    text.to_s.gsub(/\p{C}+/, '').sub(THINK_CLOSE_TAIL, '')
  end

  def accumulatable?(parsed)
    text = parsed[:text]
    return false unless text && !text.to_s.empty?
    return false unless parsed[:type].nil? || parsed[:type].to_s == 'assistant'
    return false if parsed[:think_close_only]

    true
  end
end
