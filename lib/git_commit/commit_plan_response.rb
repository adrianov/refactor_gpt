# frozen_string_literal: true

require "oj"
require "colorize"

# Parses commit-plan LLM JSON and estimates request payload size in KB.
module CommitPlanResponse
  module_function

  def parse(raw_response, payload_size_kb)
    load_plan(raw_response) || abort_unparsed!(raw_response, payload_size_kb)
  end

  def load_plan(raw_response)
    slices = OpenrouterJson.objects(raw_response.to_s)
    slices << raw_response.to_s.strip
    slices.reverse.uniq.each do |text|
      parsed = parse_candidate(text)
      return parsed if plan_like?(parsed)
    end
    nil
  end

  def abort_unparsed!(raw_response, payload_size_kb)
    puts "Failed to parse model response as JSON.".red
    puts "Payload size: #{payload_size_kb} KB".yellow
    puts "Raw response:\n#{raw_response}".red
    exit 1
  end

  def payload_size_kb(model, messages)
    body = { model: model, messages: messages, response_format: { type: "json_object" } }
    (Oj.dump(body, mode: :compat).bytesize / 1024.0).round(2)
  end

  def parse_candidate(text)
    return nil if text.nil? || text.empty?

    [text, strip_trailing_commas(text)].uniq.each do |candidate|
      return Oj.load(candidate)
    rescue Oj::ParseError
      next
    end
    nil
  end

  def plan_like?(obj)
    obj.is_a?(Hash) && obj["commits"].is_a?(Array)
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
