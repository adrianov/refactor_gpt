# frozen_string_literal: true

# Accumulates assistant text from parsed stream lines for full agent output (verification, etc.).
class AssistantTextAccumulator
  THINK_CLOSE_TAIL = /\s*`*\s*<\/think>\s*`*\s*\z/i

  def accumulate(parsed, current_output)
    return current_output unless accumulatable?(parsed)

    stripped = parsed[:text].to_s.gsub(/\p{C}+/, '').sub(THINK_CLOSE_TAIL, '')
    return current_output if stripped.empty?

    (current_output || '') + stripped + "\n"
  end

  private

  def accumulatable?(parsed)
    return false unless parsed[:text] && !parsed[:text].to_s.empty?
    return false unless parsed[:type].nil? || parsed[:type].to_s == 'assistant'

    !parsed[:think_close_only]
  end
end
