# Maps ruby-llm provider errors onto CLI semantics: balance exhaustion and usage-limit rejections
# print details and exit unretried; OpenRouter 400-wrapped upstream failures get a bounded manual
# retry, and everything else stops the process once the transport-level retries are exhausted.
module PrimaryApiErrors
  include PrimaryApiErrorBody

  MAX_RETRIES = 3
  UPSTREAM_RETRY_DELAYS = [5, 10, 30].freeze

  RESET_AT_CLAUSE = /will reset at \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/i

  private

  def translate_api_errors
    yield
  rescue RubyLLM::PaymentRequiredError => e
    exit_balance_error(402, balance_message(e.message), error_body(e))
  rescue UsageLimitCompat::UsageLimitError => e
    exit_usage_limit(e)
  rescue RubyLLM::RateLimitError => e
    handle_rate_limit(e)
  rescue RubyLLM::ServerError, RubyLLM::ServiceUnavailableError, RubyLLM::OverloadedError
    raise if @raise_on_server_error

    exhaust("❌ Server error persisted after #{MAX_RETRIES} retries")
  rescue RubyLLM::UnauthorizedError => e
    warn "❌ #{e.message}"
    exit 1
  rescue RubyLLM::BadRequestError => e
    exit_bad_request(e)
  rescue Faraday::Error, Errno::ETIMEDOUT, Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::EPIPE,
    Timeout::Error, SocketError => e
    exhaust("❌ Network/resource error persisted after #{MAX_RETRIES} retries: #{e.message}")
  end

  def exit_bad_request(error)
    warn "❌ OpenRouter rejected the request: #{error.message}"
    warn_if_present('Response body:', error_body(error))
    exit 1
  end

  # 429s are retried by the transport; surfacing here means retries are exhausted.
  def handle_rate_limit(error)
    raw = error_body(error)
    return exit_balance_error(429, balance_message(error.message), raw) if balance_exhausted?(error.message, raw)

    exhaust("❌ Rate limit exceeded after #{MAX_RETRIES} retries: #{error.message}")
  end

  # Quota/usage-limit failures are unrecoverable within a run: no retry happens. The reset time
  # shown is derived from the response's retry-after hint (now + header), because the timestamp
  # embedded in the provider message can sit hours past when requests start succeeding again.
  def exit_usage_limit(error)
    warn "❌ Unrecoverable provider usage limit: #{usage_limit_display_message(error)}"
    warn_if_present('Response body:', error_body(error))
    exit 1
  end

  def usage_limit_display_message(error)
    message = error.message.to_s
    seconds = error.retry_after_seconds
    return message unless seconds

    clause = "will reset at #{(Time.now + seconds).strftime('%Y-%m-%d %H:%M:%S')} " \
             "(#{format_duration(seconds)} from now, per retry-after)"
    message.match?(RESET_AT_CLAUSE) ? message.sub(RESET_AT_CLAUSE, clause) : "#{message} #{clause}"
  end

  # Renders a cooldown compactly for display next to the computed reset time (e.g. "10m", "8h").
  def format_duration(seconds)
    total = seconds.round
    return "#{total}s" if total < 60
    return "#{(total / 60.0).round}m" if total < 3600

    "#{(total / 3600.0).round}h"
  end

  # OpenRouter wraps upstream 429s / transient provider outages as HTTP 400, which the
  # transport does not retry — so retry those bodies here.
  def complete_with_upstream_retries
    retries = 0
    begin
      yield
    rescue RubyLLM::BadRequestError => e
      delay = UPSTREAM_RETRY_DELAYS[retries]
      raise unless delay && upstream_retryable?(e)

      retries += 1
      warn_upstream_retry(e, retries, delay)
      sleep(delay)
      retry
    end
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
end
