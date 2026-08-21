# frozen_string_literal: true

# Parse and raise primary API HTTP failures; BalanceError (Z.AI 1113) skips retry → OpenRouter.
#
# Host must implement: pretty_print_error / format_error_response (ApiErrorDisplay),
# fallback_configured?, and is_network_resource_error?
module PrimaryApiHttpErrors
  def raise_rate_limit_error(response)
    retry_after = extract_retry_after(response)
    raw = ErrorResponseBody.raw_body_from_http_response(response)
    error_message = extract_error_message_from_response(response)
    message = rate_limit_message(error_message)

    return raise_or_exit_balance_error(response.status, balance_message(error_message), raw) if balance_exhausted?(
      error_message, raw
    )

    raise RateLimitError.new(message, retry_after: retry_after, raw_body: raw)
  end

  def raise_server_error(response)
    raw = ErrorResponseBody.raw_body_from_http_response(response)
    raise ServerError.new("Server error", status: response.status, raw_body: raw)
  end

  def handle_non_success_status(response)
    raise_rate_limit_error(response) if rate_limit_response?(response)
    raise_server_error(response) if response.status >= 500 && response.status < 600
    raise_access_denied_for_fallback(response) if response.status == 403
    raise_if_response_network_error(response)
    pretty_print_error("API Error", response.status, ErrorResponseBody.format_body(response.body.to_s))
    exit 1
  end

  def raise_access_denied_for_fallback(response)
    return unless fallback_configured?

    raw = ErrorResponseBody.raw_body_from_http_response(response)
    detail = extract_error_message_from_response(response) || 'Access denied by security policy.'
    raise AccessDeniedError.new("Primary API access denied: #{detail}", status: response.status, raw_body: raw)
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
    raise BalanceError.new(message, status: status, raw_body: raw) if fallback_configured?

    detail = [message, ErrorResponseBody.format_body(raw)].reject { |s| s.to_s.strip.empty? }.join("\n\n")
    pretty_print_error("API Error", status, detail)
    exit 1
  end

  def balance_exhausted?(error_message, raw = nil)
    msg = error_message.to_s
    (!msg.empty? && (msg.include?("Insufficient balance") || msg.include?("no resource package"))) ||
      raw.to_s.match?(/"code"\s*:\s*"?1113"?/)
  end

  def extract_retry_after_from_error_response(response)
    if response.respond_to?(:headers)
      ra = extract_retry_after(response)
      return ra if ra
    end
    nested = response.response if response.respond_to?(:response)
    extract_retry_after(nested) if nested.respond_to?(:headers)
  end

  def extract_retry_after(response)
    return nil if response.nil? || !response.respond_to?(:headers)

    raw = response.headers["retry-after"]
    retry_header = raw.is_a?(Array) ? raw.first : raw
    return nil if retry_header.nil? || retry_header.to_s.strip.empty?

    Integer(retry_header)
  rescue ArgumentError, TypeError
    nil
  end

  def extract_error_message_from_response(response)
    return nil unless response&.body

    message_from_error_json(Oj.load(response.body))
  rescue Oj::ParseError
    nil
  end

  def extract_error_message_from_response_object(response)
    return nil unless response.respond_to?(:response) && response.response.respond_to?(:body)

    message_from_error_json(Oj.load(response.response.body))
  rescue Oj::ParseError
    nil
  end

  def message_from_error_json(parsed)
    return nil unless parsed.is_a?(Hash)

    error = parsed['error']
    return error if error.is_a?(String)
    return error['message'] if error.is_a?(Hash)

    nil
  end

  def extract_error_response_status(response)
    return nil unless response.respond_to?(:response) && response.response
    return nil unless response.response.respond_to?(:status)

    response.response.status
  end

  private

  def rate_limit_message(error_message)
    error_message ? "Rate limited by API: #{error_message}" : "Rate limited by API"
  end

  def balance_message(error_message)
    error_message ? "Primary API balance exhausted: #{error_message}" : "Primary API balance exhausted"
  end

  def rate_limit_response?(response, status = response.status)
    status.to_i == 429 || ErrorResponseBody.upstream_rate_limited?(response)
  end

  def raise_statusless_http_error(response, error_status)
    return raise_statusless_rate_limit(response, error_status) if rate_limit_response?(response, error_status)
    return unless error_status >= 500

    raw = ErrorResponseBody.raw_body_from_http_response(response)
    raise ServerError.new("Server error", status: error_status, raw_body: raw)
  end

  def raise_statusless_rate_limit(response, error_status)
    error_message = extract_error_message_from_response_object(response)
    raw = ErrorResponseBody.raw_body_from_http_response(response)
    if balance_exhausted?(error_message, raw)
      raise_or_exit_balance_error(error_status, balance_message(error_message), raw)
    end
    ra = extract_retry_after_from_error_response(response)
    raise RateLimitError.new(rate_limit_message(error_message), retry_after: ra, raw_body: raw)
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
