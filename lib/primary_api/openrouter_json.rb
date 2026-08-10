# frozen_string_literal: true

# Extracts JSON objects from OpenRouter text when response_format is ignored.
module OpenrouterJson
  module_function

  def valid?(text)
    return false if text.nil? || text.to_s.strip.empty?

    Oj.load(text.to_s)
    true
  rescue Oj::ParseError
    false
  end

  def extract_from_text(text)
    return nil if text.nil? || text.to_s.strip.empty?

    content = text.to_s
    from_markdown(content) || from_balanced_braces(content)
  end

  def from_markdown(content)
    json_match = content.match(/```(?:json)?\s*(\{.*\})\s*```/m)
    return nil unless json_match

    balanced_slice(json_match[1].strip)
  end

  def from_balanced_braces(content)
    brace_start = content.index("{")
    return nil unless brace_start

    brace_end = matching_brace(content, brace_start)
    return nil unless brace_end

    candidate = content[brace_start..brace_end]
    candidate if valid?(candidate)
  end

  def balanced_slice(content)
    return content if content.start_with?("{") && content.end_with?("}") && valid?(content)

    from_balanced_braces(content)
  end

  def matching_brace(content, start_pos)
    brace_count = 0

    content[start_pos..].each_char.with_index(start_pos) do |char, idx|
      case char
      when "{"
        brace_count += 1
      when "}"
        brace_count -= 1
        return idx if brace_count.zero?
      end
    end

    nil
  end
end
