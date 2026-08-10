# frozen_string_literal: true

# Shared HTTP 429 / 5xx raising for primary API clients.
# Balance exhaustion (Z.AI 1113) falls through to OpenRouter when configured; otherwise exits.
#
# Host must implement: extract_retry_after, extract_error_message_from_response,
# extract_error_message_from_response_object, extract_error_response_status,
# extract_retry_after_from_error_response, pretty_print_error (via ApiErrorDisplay),
# format_error_response, and fallback_configured?
module PrimaryApiHttpErrors
  def raise_rate_limit_error(response)
    retry_after = extract_retry_after(response)
    raw = ErrorResponseBody.raw_body_from_http_response(response)
    error_message = extract_error_message_from_response(response)
    message = error_message ? "Rate limited by API: #{error_message}" : "Rate limited by API"

    if balance_exhausted?(error_message, raw)
      raise_or_exit_balance_error(response.status, message, raw)
    end

    raise RateLimitError.new(message, retry_after: retry_after, raw_body: raw)
  end

  def raise_server_error(response)
    raw = ErrorResponseBody.raw_body_from_http_response(response)
    raise ServerError.new("Server error", status: response.status, raw_body: raw)
  end

  def handle_non_success_status(response)
    raise_rate_limit_error(response) if response.status == 429
    raise_server_error(response) if response.status >= 500 && response.status < 600
    raise_if_response_network_error(response)
    pretty_print_error("API Error", response.status, ErrorResponseBody.format_body(response.body.to_s))
    exit 1
  end

  def handle_error_response_without_status(response)
    raise_httpx_error_response_network!(response)
    error_status = extract_error_response_status(response)
    raise_statusless_http_error(response, error_status) if error_status
    raise_if_object_network_error(response)
    pretty_print_error("API Error", "Unknown", format_error_response(response))
    exit 1
  end

  def raise_or_exit_balance_error(status, message, raw)
    if fallback_configured?
      warn "⚠️  Primary API balance exhausted; trying OpenRouter fallback..."
      raise RateLimitError.new(message, retry_after: nil, raw_body: raw)
    end

    detail = [message, ErrorResponseBody.format_body(raw)].reject { |s| s.to_s.strip.empty? }.join("\n\n")
    pretty_print_error("API Error", status, detail)
    exit 1
  end

  def balance_exhausted?(error_message, raw = nil)
    balance_exhausted_message?(error_message) || balance_exhausted_body?(raw)
  end

  def balance_exhausted_message?(msg)
    return false if msg.to_s.empty?

    msg.include?("Insufficient balance") || msg.include?("no resource package")
  end

  def balance_exhausted_body?(raw)
    raw.to_s.match?(/"code"\s*:\s*"?1113"?/)
  end

  private

  def raise_statusless_http_error(response, error_status)
    return raise_statusless_rate_limit(response, error_status) if error_status == 429
    return unless error_status >= 500

    raw = ErrorResponseBody.raw_body_from_http_response(response)
    raise ServerError.new("Server error", status: error_status, raw_body: raw)
  end

  def raise_statusless_rate_limit(response, error_status)
    error_message = extract_error_message_from_response_object(response)
    raw = ErrorResponseBody.raw_body_from_http_response(response)
    message = error_message ? "Rate limited by API: #{error_message}" : "Rate limited by API"
    raise_or_exit_balance_error(error_status, message, raw) if balance_exhausted?(error_message, raw)
    ra = extract_retry_after_from_error_response(response)
    raise RateLimitError.new(message, retry_after: ra, raw_body: raw)
  end

  def raise_if_response_network_error(response)
    error_message = extract_error_message_from_response(response)
    error_message ||= response.error.to_s if response.respond_to?(:error)
    error_message ||= response.message.to_s if response.respond_to?(:message)
    raise_network_resource!(error_message) if error_message
    raise_network_resource!(response.body.to_s) if response&.body
  end

  def raise_httpx_error_response_network!(response)
    return unless response.class.name == "HTTPX::ErrorResponse"

    err_msg = (response.error.to_s if response.respond_to?(:error) && response.error)
    err_msg ||= response.message.to_s if response.respond_to?(:message)
    raise_network_resource!(err_msg) if err_msg.to_s != ""
  end

  def raise_if_object_network_error(response)
    raise_network_resource!(error_message_from_object(response))
    nested = response.response if response.respond_to?(:response)
    return unless nested.respond_to?(:body) && nested.body

    raise_network_resource!(nested.body.to_s)
  end

  def error_message_from_object(response)
    message = extract_error_message_from_response_object(response)
    message ||= response.error.to_s if response.respond_to?(:error)
    message || (response.message.to_s if response.respond_to?(:message))
  end

  def raise_network_resource!(message)
    return unless message && is_network_resource_error?(message)

    raise NetworkResourceError.new("Network/resource error: #{message}")
  end
end
