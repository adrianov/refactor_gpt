# frozen_string_literal: true

require 'oj'

# Maps ruby-llm provider errors onto CLI semantics: balance exhaustion prints and exits,
# OpenRouter 400-wrapped upstream failures get a bounded manual retry, and everything else
# stops the process once the transport-level retries are exhausted. Also carries the
# payload helpers that read and format those error bodies.
module PrimaryApiErrors
  MAX_RETRIES = 3
  UPSTREAM_RETRY_DELAYS = [5, 10, 30].freeze

  private

  def translate_api_errors
    yield
  rescue RubyLLM::PaymentRequiredError => e
    exit_balance_error(402, balance_message(e.message), error_body(e))
  rescue RubyLLM::RateLimitError => e
    handle_rate_limit(e)
  rescue RubyLLM::ServerError, RubyLLM::ServiceUnavailableError, RubyLLM::OverloadedError
    raise if @raise_on_server_error

    exhaust("❌ Server error persisted after #{MAX_RETRIES} retries")
  rescue RubyLLM::UnauthorizedError => e
    warn "❌ #{e.message}"
    exit 1
  rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Errno::ETIMEDOUT, Timeout::Error => e
    exhaust("❌ Network/resource error persisted after #{MAX_RETRIES} retries: #{e.message}")
  end

  # 429s are retried by the transport; surfacing here means retries are exhausted.
  def handle_rate_limit(error)
    raw = error_body(error)
    return exit_balance_error(429, balance_message(error.message), raw) if balance_exhausted?(error.message, raw)

    exhaust("❌ Rate limit exceeded after #{MAX_RETRIES} retries: #{error.message}")
  end

  # OpenRouter wraps upstream 429s / transient provider outages as HTTP 400, which the
  # transport does not retry — so retry those bodies here.
  def complete_with_upstream_retries
    attempt = 0
    yield
  rescue RubyLLM::BadRequestError => e
    delay = UPSTREAM_RETRY_DELAYS[attempt]
    raise unless delay && upstream_retryable?(e)

    warn_upstream_retry(e, attempt += 1, delay)
    sleep(delay)
    retry
  end

  def upstream_retryable?(error)
    raw = error_body(error)
    upstream_rate_limited?(raw) ||
      is_network_resource_error?(error.message) || is_network_resource_error?(raw)
  end

  def warn_upstream_retry(error, attempt, delay)
    if attempt == 1
      endpoint = primary_api_error_endpoint.to_s.strip
      warn "Primary API endpoint: #{endpoint}" unless endpoint.empty?
      warn_if_present('Primary API HTTP 400 response body:', error_body(error))
    end
    warn "⚠️  Upstream provider error (400), retrying in #{delay}s... (#{attempt}/#{MAX_RETRIES})"
  end

  def exhaust(message)
    warn message
    exit 1
  end

  def exit_balance_error(status, message, raw)
    detail = [message, format_body(raw)].reject { |s| s.to_s.strip.empty? }.join("\n\n")
    warn "❌ API Error (HTTP #{status})"
    warn detail
    exit 1
  end

  def balance_message(error_message)
    error_message ? "Primary API balance exhausted: #{error_message}" : 'Primary API balance exhausted'
  end

  # Balance-exhausted requests must never be retried: message phrases plus the 1113 data code.
  def balance_exhausted?(error_message, raw = nil)
    msg = error_message.to_s
    (!msg.empty? && (msg.include?('Insufficient balance') || msg.include?('no resource package'))) ||
      raw.to_s.match?(/"code"\s*:\s*"?1113"?/)
  end

  def is_network_resource_error?(error_message)
    msg = error_message.to_s
    msg.match?(/\bnetwork\s+error\b/i) || msg.include?('please try again later') ||
      msg.include?('resource_exhausted') || msg.match?(/connection\s+stalled/i) ||
      msg.include?('CANCEL') || msg.include?('canceled') ||
      msg.include?('stream closed') || msg.include?('closed with error') || msg.include?('0x8') ||
      msg.include?('SSL_read: unexpected eof while reading')
  end

  def primary_api_error_endpoint
    "#{@api_base_url}/chat/completions"
  end

  # Reads the raw provider payload off a ruby-llm error (middleware runs before Faraday's
  # JSON parser, so the body is a String).
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

  # OpenRouter signals upstream rate limits with HTTP 400 plus either a "rate-limited
  # upstream" phrase or a 429 in error/metadata.previous_errors.
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
