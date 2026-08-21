# frozen_string_literal: true

require "oj"

# Formats HTTP API error bodies for CLI (pretty JSON when possible).
# Detects OpenRouter wrappers where HTTP 400 embeds an upstream provider 429.
module ErrorResponseBody
  class << self
    def raw_body_from_http_response(response)
      return "" if response.nil?

      s = extract_body(response)
      return s if s.strip != ""

      nested = response.response if response.respond_to?(:response)
      extract_body(nested)
    end

    def format_body(text)
      str = text.to_s
      return str if str.strip.empty?

      pretty = pretty_json(str)
      pretty || str
    end

    def warn_if_present(heading, body)
      raw = body.to_s.strip
      return if raw.empty?

      warn heading unless heading.to_s.strip.empty?
      warn format_body(raw)
    end

    def pretty_json(str)
      parsed = Oj.load(str)
      return nil unless parsed.is_a?(Hash) || parsed.is_a?(Array)

      Oj.dump(parsed, mode: :compat, indent: 2)
    rescue Oj::ParseError, TypeError
      nil
    end

    def upstream_rate_limited?(body_or_response)
      raw = body_text(body_or_response)
      return false if raw.strip.empty?
      return true if raw.match?(/rate[- ]?limited upstream/i)

      error_json_rate_limited?(raw)
    end

    private

    def body_text(body_or_response)
      return body_or_response.to_s unless body_or_response.respond_to?(:body) ||
                                          body_or_response.respond_to?(:response)

      raw_body_from_http_response(body_or_response)
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

    def extract_body(obj)
      return "" if obj.nil? || !obj.respond_to?(:body) || obj.body.nil?

      obj.body.to_s
    end
  end
end
