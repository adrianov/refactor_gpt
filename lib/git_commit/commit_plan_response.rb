# frozen_string_literal: true

require "oj"
require "colorize"

# Parses commit-plan LLM JSON and estimates request payload size in KB.
module CommitPlanResponse
  module_function

  def parse(raw_response, payload_size_kb)
    [raw_response.strip, extract_json_object(raw_response)].each do |candidate|
      next unless candidate

      [candidate, strip_trailing_commas(candidate)].uniq.each do |text|
        return Oj.load(text)
      rescue Oj::ParseError
        next
      end
    end

    puts "Failed to parse model response as JSON.".red
    puts "Payload size: #{payload_size_kb} KB".yellow
    puts "Raw response:\n#{raw_response}".red
    exit 1
  end

  def payload_size_kb(model, messages)
    body = { model: model, messages: messages, response_format: { type: "json_object" } }
    (Oj.dump(body, mode: :compat).bytesize / 1024.0).round(2)
  end

  def extract_json_object(text)
    start = text.index("{")
    finish = text.rindex("}")
    text[start..finish] if start && finish && finish > start
  end

  # Drop commas that trail a value before } or ], ignoring commas inside JSON strings.
  def strip_trailing_commas(text)
    s = text.to_s
    out = +""
    i = 0
    in_string = false
    escape = false
    while i < s.length
      ch = s[i]
      if in_string
        out << ch
        in_string, escape = update_string_state(ch, escape)
      elsif ch == '"'
        in_string = true
        out << ch
      elsif !(ch == "," && trailing_comma?(s, i))
        out << ch
      end
      i += 1
    end
    out
  end

  def update_string_state(ch, escape)
    return [true, false] if escape
    return [true, true] if ch == "\\"
    return [false, false] if ch == '"'

    [true, false]
  end

  def trailing_comma?(s, i)
    j = i + 1
    j += 1 while j < s.length && s[j].match?(/\s/)
    j < s.length && (s[j] == "}" || s[j] == "]")
  end
end
