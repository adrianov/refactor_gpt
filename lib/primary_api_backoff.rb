# frozen_string_literal: true

# Primary API retry steps; when OpenRouter is configured, the first retry-worthy error is re-raised for fallback.
module PrimaryApiBackoff
  def self.included(base)
    base.include(Methods)
    base.send(:private, *Methods.instance_methods(false))
  end

  module Methods
    def rethrow_for_openrouter_fallback(error)
      return unless fallback_configured?

      if error.is_a?(NetworkResourceError) || error.is_a?(RateLimitError) || error.is_a?(ServerError)
        raise error
      end

      raise NetworkResourceError, "Network/resource error: #{error.message}"
    end

    def primary_backoff_after_httpx(e, retries, max_retries, base_delay)
      rethrow_for_openrouter_fallback(e)
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
      rethrow_for_openrouter_fallback(e)
      r = retries + 1
      if r > max_retries
        exhaust_retry(e, "❌ Network/resource error persisted after #{max_retries} retries: #{e.message}")
      end
      handle_network_resource_retry(e, r, max_retries, base_delay)
      r
    end

    def primary_backoff_rate_limit(e, retries, max_retries, base_delay)
      rethrow_for_openrouter_fallback(e)
      r = retries + 1
      if r > max_retries
        exhaust_retry(e, "❌ Rate limit exceeded after #{max_retries} retries: #{e.message}")
      end
      handle_rate_limit_retry(e, r, max_retries, base_delay)
      r
    end

    def primary_backoff_server(e, retries, max_retries, base_delay)
      rethrow_for_openrouter_fallback(e)
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
  end
end
