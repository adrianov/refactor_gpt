# frozen_string_literal: true

# OpenRouter fallback for primary API outages, plus once-per-request error-body warnings.
# Host must set @openrouter_client, @max_completion_tokens, @model, @last_payload_bytes,
# and primary_api_error_endpoint.
module PrimaryApiFallback
  FALLBACK_ERRORS = [BalanceError, RateLimitError, ServerError, NetworkResourceError].freeze

  def self.included(base)
    base.class_eval do
      private :reset_primary_error_body_warned!, :warn_primary_api_error_body_once,
        :warn_rate_limit_body_on_first_retry, :warn_server_body_on_first_retry,
        :warn_primary_api_endpoint_line, :handle_openrouter_failure, :raise_on_server_error?,
        :openrouter_exhaust_should_raise?
    end
  end

  def with_openrouter_fallback(messages, json: false)
    reset_primary_error_body_warned!
    yield
  rescue *FALLBACK_ERRORS => e
    warn_primary_api_error_body_once(e)
    answer = try_openrouter(messages, json: json)
    return answer if answer

    handle_openrouter_failure(e)
  end

  def try_openrouter(messages, json: false)
    return nil unless fallback_configured?

    warn "⚠️  Primary API unavailable, trying OpenRouter fallback... #{format_payload_size}"
    @openrouter_client.ask(messages, json: json, max_completion_tokens: @max_completion_tokens,
      source_model: @model)
  rescue StandardError => e
    warn "⚠️  OpenRouter fallback failed: #{e.message}"
    nil
  end

  def fallback_configured?
    @openrouter_client&.configured?
  end

  def build_openrouter_client
    OpenrouterClient.new(
      api_key: fetch_env("OPENROUTER_API_KEY", nil),
      api_base_url: fetch_env("OPENROUTER_BASE_URL", OpenrouterClient::DEFAULT_BASE_URL),
      model: fetch_env("OPENROUTER_MODEL", OpenrouterClient::DEFAULT_MODEL),
      proxy_url: @proxy_url,
      request_timeout: @request_timeout,
      debug: @debug
    )
  end

  def format_payload_size
    return "" unless @last_payload_bytes

    bytes = @last_payload_bytes
    size = bytes >= 1_048_576 ? "#{(bytes / 1_048_576.0).round(2)} MB" : "#{(bytes / 1024.0).round(2)} KB"
    "(payload: #{size})"
  end

  def exhaust_retry(error, message)
    if openrouter_exhaust_should_raise?(error)
      warn "#{message}#{fallback_configured? ? " Trying OpenRouter fallback..." : ""}"
      raise error
    end

    warn message
    exit 1
  end

  def exhaust_httpx_network_retries(e, max_retries)
    exhaust_retry(e, "❌ Network/resource error persisted after #{max_retries} retries: #{e.message}")
  end

  def retry_failure_message(error)
    case error
    when BalanceError
      "❌ Primary API balance exhausted after OpenRouter fallback: #{error.message}"
    when RateLimitError
      "❌ Rate limit exceeded after OpenRouter fallback: #{error.message}"
    when ServerError
      "❌ Server error (#{error.status}) persisted after OpenRouter fallback: #{error.message}"
    when NetworkResourceError
      "❌ Network/resource error persisted after OpenRouter fallback: #{error.message}"
    else
      "❌ Request failed after OpenRouter fallback: #{error.message}"
    end
  end

  def reset_primary_error_body_warned!
    @primary_api_error_body_warned = false
  end

  def warn_primary_api_error_body_once(error)
    return if @primary_api_error_body_warned
    return unless error.is_a?(BalanceError) || error.is_a?(RateLimitError) || error.is_a?(ServerError)

    body = error.raw_body.to_s.strip
    return if body.empty?

    warn_primary_api_endpoint_line
    ErrorResponseBody.warn_if_present("Primary API error response body:", body)
    @primary_api_error_body_warned = true
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

  private

  def openrouter_exhaust_should_raise?(error)
    fallback_configured? || (error.is_a?(ServerError) && raise_on_server_error?)
  end

  def handle_openrouter_failure(error)
    raise error if error.is_a?(ServerError) && raise_on_server_error?

    warn_primary_api_error_body_once(error)
    warn retry_failure_message(error)
    exit 1
  end

  def raise_on_server_error?
    instance_variable_defined?(:@raise_on_server_error) && @raise_on_server_error
  end
end
