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

  # Models often emit a trailing comma before } or ] in otherwise valid plans.
  def strip_trailing_commas(text)
    text.to_s.gsub(/,(\s*[}\]])/, '\1')
  end
end
