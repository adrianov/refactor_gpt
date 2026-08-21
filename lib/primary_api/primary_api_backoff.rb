# frozen_string_literal: true

# Primary API retry steps with exponential backoff for rate limits, server errors, and network issues.
# Balance-style dead ends print and exit via PrimaryApiHttpErrors instead of retrying.
#
# Host must implement: raise_on_server_error?, is_network_resource_error?,
# and primary_api_error_endpoint (for the once-per-request error-body warnings below).
module PrimaryApiBackoff
  def self.included(base)
    base.prepend(NetworkErrors)
    base.include(Methods)
    base.send(:private, *Methods.instance_methods(false))
  end

  # Shared provider error phrases that should be handled as transient network failures.
  module NetworkErrors
    def is_network_resource_error?(error_message)
      api_network_error?(error_message) || super
    end
    private :is_network_resource_error?

    private

    def api_network_error?(error_message)
      error_message.to_s.match?(/network error,\s*error id:/i)
    end
  end

  module Methods
    def primary_backoff_after_httpx(e, retries, max_retries, base_delay)
      if is_network_resource_error?(e.message.to_s)
        primary_backoff_network_httpx(e, retries, max_retries, base_delay)
      else
        primary_backoff_connection_httpx(e, retries, max_retries, base_delay)
      end
    end

    def primary_backoff_network_httpx(e, retries, max_retries, base_delay)
      r = retries + 1
      exhaust_httpx_network_retries(e, max_retries) if r > max_retries

      handle_network_resource_retry(e, r, max_retries, base_delay)
      r
    end

    def primary_backoff_connection_httpx(e, retries, max_retries, base_delay)
      r = retries + 1
      raise e if r > max_retries

      handle_retry_with_exponential_backoff(e, r, max_retries, base_delay)
      r
    end

    def primary_backoff_network_resource(e, retries, max_retries, base_delay)
      r = retries + 1
      if r > max_retries
        exhaust_retry(e, "❌ Network/resource error persisted after #{max_retries} retries: #{e.message}")
      end
      handle_network_resource_retry(e, r, max_retries, base_delay)
      r
    end

    def primary_backoff_rate_limit(e, retries, max_retries, base_delay)
      r = retries + 1
      if r > max_retries
        exhaust_retry(e, "❌ Rate limit exceeded after #{max_retries} retries: #{e.message}")
      end
      handle_rate_limit_retry(e, r, max_retries, base_delay)
      r
    end

    def primary_backoff_server(e, retries, max_retries, base_delay)
      r = retries + 1
      if r > max_retries
        exhaust_retry(e, "❌ Server error persisted after #{max_retries} retries")
      end
      handle_server_error_retry(e, r, max_retries, base_delay)
      r
    end

    def retry_with_backoff(max_retries: 3, base_delay: 1)
      retries = 0

      begin
        yield
      rescue HTTPX::Connection::HTTP2::GoawayError,
        HTTPX::TimeoutError,
        HTTPX::ConnectionError => e
        retries = primary_backoff_after_httpx(e, retries, max_retries, base_delay)
        retry
      rescue NetworkResourceError => e
        retries = primary_backoff_network_resource(e, retries, max_retries, base_delay)
        retry
      rescue RateLimitError => e
        retries = primary_backoff_rate_limit(e, retries, max_retries, base_delay)
        retry
      rescue ServerError => e
        retries = primary_backoff_server(e, retries, max_retries, base_delay)
        retry
      end
    end

    def execute_with_network_retry(max_retries: 3, base_delay: 1)
      retries = 0
      begin
        yield
      rescue NetworkResourceError => e
        retries += 1
        if retries <= max_retries
          handle_network_resource_retry(e, retries, max_retries, base_delay)
          retry
        else
          exhaust_retry(e, "❌ Network/resource error persisted after #{max_retries} retries: #{e.message}")
        end
      end
    end

    def handle_retry_with_exponential_backoff(error, retries, max_retries, base_delay)
      delay = base_delay * (2**(retries - 1))
      error_name = error.class.name.split("::").last
      warn "⚠️  Connection issue (#{error_name}), retrying in #{delay}s... (#{retries}/#{max_retries})"
      sleep(delay)
    end

    def handle_network_resource_retry(_error, retries, max_retries, base_delay)
      delay = base_delay * (2**(retries - 1))
      warn "⚠️  Network/resource error, retrying in #{delay}s... (#{retries}/#{max_retries})"
      sleep(delay)
    end

    def handle_rate_limit_retry(error, retries, max_retries, _base_delay)
      warn_rate_limit_body_on_first_retry(error, retries)
      delays = [5, 10, 30]
      delay = error.retry_after || delays[retries - 1] || delays.last
      error_msg = error.message.include?("Rate limited by API:") ? error.message.split(": ", 2).last : nil
      base_msg = "⚠️  Rate limited (429)"
      msg = error_msg ? "#{base_msg}: #{error_msg}" : base_msg
      warn "#{msg}, retrying in #{delay}s... (#{retries}/#{max_retries})"
      sleep(delay)
    end

    def handle_server_error_retry(error, retries, max_retries, base_delay)
      warn_server_body_on_first_retry(error, retries)
      delay = base_delay * (2**(retries - 1))
      warn "⚠️  Server error (#{error.status}), retrying in #{delay}s... (#{retries}/#{max_retries})"
      sleep(delay)
    end

    def exhaust_httpx_network_retries(e, max_retries)
      exhaust_retry(e, "❌ Network/resource error persisted after #{max_retries} retries: #{e.message}")
    end

    # Stops the process when retries are exhausted, unless the host asked server errors to propagate.
    def exhaust_retry(error, message)
      raise error if error.is_a?(ServerError) && raise_on_server_error?

      warn message
      exit 1
    end

    def warn_rate_limit_body_on_first_retry(error, retries)
      return unless retries == 1 && error.is_a?(RateLimitError) && !error.raw_body.to_s.strip.empty?

      warn_primary_api_endpoint_line
      ErrorResponseBody.warn_if_present("Primary API HTTP 429 response body:", error.raw_body)
    end

    def warn_server_body_on_first_retry(error, retries)
      return unless retries == 1 && error.is_a?(ServerError) && !error.raw_body.to_s.strip.empty?

      warn_primary_api_endpoint_line
      ErrorResponseBody.warn_if_present("Primary API HTTP #{error.status} response body:", error.raw_body)
    end

    def warn_primary_api_endpoint_line
      return unless respond_to?(:primary_api_error_endpoint, true)

      ep = send(:primary_api_error_endpoint).to_s.strip
      warn "Primary API endpoint: #{ep}" unless ep.empty?
    end
  end
end
