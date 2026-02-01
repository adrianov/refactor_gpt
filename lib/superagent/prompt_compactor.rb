# frozen_string_literal: true

# Compacts agent prompts over a size limit: deduplicates consecutive lines, then truncates at newline.
class PromptCompactor
  MAX_PROMPT_BYTES = 100 * 1024

  def self.compact(prompt, max_bytes: MAX_PROMPT_BYTES)
    s = prompt.to_s
    return s if s.bytesize <= max_bytes

    deduped = remove_consecutive_duplicate_lines(s)
    return deduped if deduped.bytesize <= max_bytes

    truncate_at_newline(deduped, max_bytes)
  end

  def self.remove_consecutive_duplicate_lines(text)
    prev = nil
    text.each_line.with_object(String.new) do |line, acc|
      next if line == prev

      acc << line
      prev = line
    end
  end

  def self.truncate_at_newline(text, max_bytes)
    return text.byteslice(0, max_bytes) if max_bytes <= 0

    byte_pos = 0
    last_newline_byte = 0
    text.each_char do |c|
      break if byte_pos >= max_bytes

      byte_pos += c.bytesize
      last_newline_byte = byte_pos if c == "\n"
    end
    keep = last_newline_byte > 0 ? last_newline_byte : max_bytes
    text.byteslice(0, keep)
  end
end
