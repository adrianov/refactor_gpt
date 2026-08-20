# frozen_string_literal: true

require 'oj'

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

  def objects(content)
    found = []
    text = content.to_s
    each_unquoted_index(text) do |i, ch|
      next unless ch == '{'

      finish = matching_brace(text, i)
      found << text[i..finish] if finish
    end
    found
  end

  def from_markdown(content)
    json_match = content.match(/```(?:json)?\s*(\{.*\})\s*```/m)
    return nil unless json_match

    balanced_slice(json_match[1].strip)
  end

  def from_balanced_braces(content)
    best_object(objects(content))
  end

  def balanced_slice(content)
    return content if content.start_with?('{') && content.end_with?('}') && valid?(content)

    from_balanced_braces(content)
  end

  def matching_brace(content, start_pos)
    depth = 0
    in_string = false
    escape = false
    (start_pos...content.length).each do |idx|
      ch = content[idx]
      if in_string
        in_string, escape = next_string_state(ch, escape)
        next
      end

      case ch
      when '"' then in_string = true
      when '{' then depth += 1
      when '}'
        depth -= 1
        return idx if depth.zero?
      end
    end
    nil
  end

  def each_unquoted_index(text)
    in_string = false
    escape = false
    text.length.times do |i|
      ch = text[i]
      if in_string
        in_string, escape = next_string_state(ch, escape)
      elsif ch == '"'
        in_string = true
      else
        yield i, ch
      end
    end
  end

  def next_string_state(ch, escape)
    return [true, false] if escape
    return [true, true] if ch == '\\'
    return [false, false] if ch == '"'

    [true, false]
  end

  def best_object(candidates)
    valid = candidates.select { |c| valid?(c) }
    return nil if valid.empty?

    longest = valid.map(&:length).max
    valid.reverse.find { |c| c.length >= (longest * 4 / 5) }
  end
end
