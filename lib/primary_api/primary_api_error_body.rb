# frozen_string_literal: true

require 'oj'

# Reads, formats, and classifies provider error payloads.
module PrimaryApiErrorBody
  private

  def error_body(error)
    return '' unless error.respond_to?(:response) && error.response.respond_to?(:body)

    error.response.body.to_s
  end

  def format_body(text)
    str = text.to_s
    return str if str.strip.empty?

    pretty_json(str) || str
  end

  def warn_if_present(heading, body)
    raw = body.to_s.strip
    return if raw.empty?

    warn heading
    warn format_body(raw)
  end

  def upstream_rate_limited?(raw_body)
    raw = raw_body.to_s
    return false if raw.strip.empty?
    return true if raw.match?(/rate[- ]?limited upstream/i)

    error_json_rate_limited?(raw)
  end

  def pretty_json(str)
    parsed = Oj.load(str)
    return nil unless parsed.is_a?(Hash) || parsed.is_a?(Array)

    Oj.dump(parsed, mode: :compat, indent: 2)
  rescue Oj::ParseError, TypeError
    nil
  end

  def error_json_rate_limited?(raw)
    error = Oj.load(raw)
    error = error['error'] if error.is_a?(Hash)
    return false unless error.is_a?(Hash)
    return true if error['code'].to_i == 429

    Array(error.dig('metadata', 'previous_errors')).any? do |entry|
      entry.is_a?(Hash) && entry['code'].to_i == 429
    end
  rescue Oj::ParseError, TypeError
    false
  end
end
