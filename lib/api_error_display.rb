# frozen_string_literal: true

# Shared pretty-print helpers for primary API HTTP failures (OpenAI-compatible and Gemini).
module ApiErrorDisplay
  def pretty_print_error(error_type, status, details)
    print_error_header(error_type, status)
    print_error_details(details)
    print_error_suggestions(error_type)
  end

  def print_error_header(error_type, status)
    puts
    puts "❌ #{error_type}"
    puts "┌─ #{"─" * 50}"
    puts "│ Status: #{status}"
    puts "│ Time: #{Time.now.strftime("%Y-%m-%d %H:%M:%S")}"
    puts "├─ #{"─" * 50}"
  end

  def print_error_details(details)
    puts "│ Details:"
    details.to_s.split("\n").each { |line| puts "│ #{line}" }
    puts "└─ #{"─" * 50}"
    puts
  end

  def format_error_response(response)
    parts = []
    add_error_details(parts, response)
    add_response_details(parts, response)
    add_full_inspect(parts, response)
    parts.join("\n")
  end

  def add_error_details(parts, response)
    parts << "Class: #{response.class}"
    parts << "Error: #{response.error}" if response.respond_to?(:error) && response.error
    parts << "Message: #{response.message}" if response.respond_to?(:message) && response.message
    parts << "Request: #{response.request}" if response.respond_to?(:request) && response.request
  end

  def add_response_details(parts, response)
    return unless response.respond_to?(:response) && response.response

    parts << "Response Status: #{response.response.status}" if response.response.respond_to?(:status)
    add_response_body(parts, response)
  end

  def add_response_body(parts, response)
    return unless response.response.respond_to?(:body) && response.response.body

    parts << "Response Body: #{response.response.body}"
  end

  def add_full_inspect(parts, response)
    parts << "Full Inspect:"
    parts << response.inspect
  end

  def print_error_suggestions(error_type)
    suggestions = error_suggestions(error_type)
    return unless suggestions

    puts "💡 Suggestions:"
    suggestions.each { |suggestion| puts "   #{suggestion}" }
    puts
  end

  def handle_http_error(error)
    error_message = error.message.to_s

    if is_network_resource_error?(error_message)
      raise NetworkResourceError.new("Network/resource error: #{error.message}")
    end

    pretty_print_error(http_error_type(error), "Network Error", error.message)
    exit 1
  end

  def handle_parse_error(error, response)
    warn "Failed to parse JSON response: #{error.message}"
    warn response.body if defined?(response) && response&.body
    exit 1
  end

  def http_error_type(error)
    case error
    when HTTPX::Connection::HTTP2::GoawayError
      "Connection Closed (HTTP/2)"
    when HTTPX::TimeoutError
      "Request Timeout"
    when HTTPX::ResolveError
      "DNS Resolution Failed"
    when HTTPX::ConnectionError
      "Connection Failed"
    else
      error.class.name.split("::").last
    end
  end

  def error_suggestions(error_type)
    case error_type
    when "Connection Closed (HTTP/2)", "Connection Failed"
      ["• Check your internet connection",
        "• Try again in a few moments",
        "• Verify API endpoint is accessible"]
    when "Request Timeout"
      ["• Request was too large or server is busy",
        "• Try with a shorter prompt",
        "• Check REQUEST_TIMEOUT environment variable"]
    when "DNS Resolution Failed"
      ["• Check your DNS settings",
        "• Verify API base URL environment variable",
        "• Try using a different network"]
    when "API Error"
      ["• Check your API access token",
        "• Verify API quota and billing",
        "• Check if the model is available"]
    end
  end
end
