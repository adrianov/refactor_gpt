# frozen_string_literal: true

# Once-per-request warning of primary API error bodies before OpenRouter or final failure.
# Host must implement `primary_api_error_endpoint` (full URL of the failing request).
module PrimaryApiErrorBody
  def self.included(base)
    base.class_eval do
      private :reset_primary_error_body_warned!, :warn_primary_api_error_body_once,
        :warn_rate_limit_body_on_first_retry, :warn_server_body_on_first_retry,
        :warn_primary_api_endpoint_line
    end
  end

  def reset_primary_error_body_warned!
    @primary_api_error_body_warned = false
  end

  def warn_primary_api_error_body_once(error)
    return if @primary_api_error_body_warned
    return unless error.is_a?(RateLimitError) || error.is_a?(ServerError)

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
end
