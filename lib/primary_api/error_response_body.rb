# frozen_string_literal: true

require "oj"

# Formats HTTP API error bodies for CLI (pretty JSON when possible).
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

    private

    def extract_body(obj)
      return "" if obj.nil? || !obj.respond_to?(:body) || obj.body.nil?

      obj.body.to_s
    end
  end
end
