# frozen_string_literal: true

# Shared filter for stream output: think-closing tag should not be displayed.
module StreamFilter
  # Final think block closing tag sometimes echoed as assistant or thinking; do not display.
  THINK_CLOSE_ONLY = /\A\s*`*\s*<\/think>\s*`*\s*\z/i
  # Trailing think-close at end of chunk (optional backticks/whitespace around tag).
  THINK_CLOSE_TAIL = /\s*`*\s*<\/think>\s*`*\s*\z/i

  def self.think_close_only?(text)
    return false if text.nil? || text.to_s.strip.empty?
    normalized = text.to_s.strip.gsub(/\p{C}+/, '')
    normalized.match?(THINK_CLOSE_ONLY)
  end

  # Strip trailing think-close from chunk so the tag is never shown. Returns stripped string.
  def self.strip_trailing_think_close(text)
    return text if text.nil? || text.to_s.empty?
    s = text.to_s.gsub(/\p{C}+/, '')
    s.sub(THINK_CLOSE_TAIL, '')
  end
end
