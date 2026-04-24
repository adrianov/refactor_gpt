#!/usr/bin/env ruby
# frozen_string_literal: true

require "httpx"
require "oj"
require "ruby-progressbar"

# Custom error for rate limiting (429)
class RateLimitError < StandardError
  attr_reader :retry_after, :raw_body

  def initialize(message = "Rate limited", retry_after: nil, raw_body: nil)
    @retry_after = retry_after
    @raw_body = raw_body
    super(message)
  end
end

# Custom error for server errors (5xx)
class ServerError < StandardError
  attr_reader :status, :raw_body

  def initialize(message = "Server error", status: 500, raw_body: nil)
    @status = status
    @raw_body = raw_body
    super(message)
  end
end

# Custom error for network/resource errors that should be retried
class NetworkResourceError < StandardError
end

# Unified OpenAI client with proxy support for all GPT utilities
class OpenAiClient
  include AgentsFileHandler
  include PrimaryApiBackoff
  include PrimaryApiErrorBody
  attr_reader :model
DEFAULT_MODEL = "glm-5.1"
  REQUEST_TIMEOUT = 300
  DEFAULT_PROGRESS_SPEED = 300
  PROGRESS_SPEED_FILE = File.join(Dir.home, ".refactor_gpt").freeze

  def initialize(model: nil, debug: false, max_completion_tokens: nil,
    progress_title: nil, api_base_url: nil, api_key: nil, raise_on_server_error: false)
    @api_base_url = api_base_url || fetch_env("OPENAI_BASE_URL", "https://api.openai.com/v1")
    @api_key = api_key || fetch_env("OPENAI_ACCESS_TOKEN")
    @proxy_url = fetch_env("PROXY_URL", nil)
    @model = model || fetch_env("DEFAULT_MODEL", DEFAULT_MODEL)
    @debug = debug
    @max_completion_tokens = max_completion_tokens
    @progress_title = progress_title
    @env_vars = nil
    @request_timeout = Integer(fetch_env("REQUEST_TIMEOUT", REQUEST_TIMEOUT))
    @progress_mutex = Mutex.new
    @progress_stop = false
    @raise_on_server_error = raise_on_server_error
    @openrouter_client = build_openrouter_client
  end

  def ask(messages, json: false, title: nil)
    title ||= @progress_title
    with_openrouter_fallback(messages, json: json) do
      title ? perform_progress_request(messages, json: json, title: title) : perform_request(messages, json: json)
    end
  rescue Oj::ParseError => e
    handle_parse_error(e, response)
  end

  private

  def perform_request(messages, json: false)
    execute_with_network_retry { make_request_with_debug(messages, json: json) }
  rescue HTTPX::Error => e
    raise NetworkResourceError, "Network/resource error: #{e.message}" if is_network_resource_error?(e.message.to_s)

    handle_http_error(e)
  end

  def perform_progress_request(messages, json: false, title: nil)
    execute_with_network_retry { setup_progress_tracking(messages, json: json, title: title) }
  rescue HTTPX::Error => e
    raise NetworkResourceError, "Network/resource error: #{e.message}" if is_network_resource_error?(e.message.to_s)

    handle_http_error(e)
  end

  def with_openrouter_fallback(messages, json: false)
    reset_primary_error_body_warned!
    yield
  rescue RateLimitError, ServerError, NetworkResourceError => e
    warn_primary_api_error_body_once(e)
    answer = try_openrouter(messages, json: json)
    return answer if answer

    handle_retry_failure(e)
  end

  def try_openrouter(messages, json: false)
    return nil unless fallback_configured?

    warn "⚠️  Primary API unavailable, trying OpenRouter fallback... #{format_payload_size}"
    @openrouter_client.ask(messages, json: json, max_completion_tokens: @max_completion_tokens,
      source_model: @model)
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

  def exhaust_retry(error, message)
    if fallback_configured? || (error.is_a?(ServerError) && @raise_on_server_error)
      warn "#{message}#{fallback_configured? ? " Trying OpenRouter fallback..." : ""}"
      raise error
    end

    warn message
    exit 1
  end

  def handle_retry_failure(error)
    raise error if error.is_a?(ServerError) && @raise_on_server_error

    warn_primary_api_error_body_once(error)
    warn retry_failure_message(error)
    exit 1
  end

  def retry_failure_message(error)
    case error
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

  def exhaust_httpx_network_retries(e, max_retries)
    exhaust_retry(e, "❌ Network/resource error persisted after #{max_retries} retries: #{e.message}")
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

  def is_network_resource_error?(error_message)
    msg = error_message.to_s
    msg.include?("resource_exhausted") || msg.match?(/connection\s+stalled/i) ||
      msg.include?("CANCEL") || msg.include?("canceled") ||
      msg.include?("stream closed") || msg.include?("closed with error") || msg.include?("0x8") ||
      msg.include?("SSL_read: unexpected eof while reading")
  end

  # Outer retry after inner `retry_with_backoff` gives up. When OpenRouter is configured,
  # `PrimaryApiBackoff` re-raises the first `NetworkResourceError` from the inner block; that
  # exception is still caught here, so `rethrow_for_openrouter_fallback` must run again — otherwise
  # this loop would sleep and retry instead of propagating to `with_openrouter_fallback`.
  def execute_with_network_retry(max_retries: 3, base_delay: 1)
    retries = 0
    begin
      yield
    rescue NetworkResourceError => e
      rethrow_for_openrouter_fallback(e)

      retries += 1
      if retries <= max_retries
        handle_network_resource_retry(e, retries, max_retries, base_delay)
        retry
      else
        exhaust_retry(e, "❌ Network/resource error persisted after #{max_retries} retries: #{e.message}")
      end
    end
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

  def build_request_body(messages, json: false)
    body = {model: @model, messages: messages}
    body[:response_format] = {type: "json_object"} if json
    body[:max_completion_tokens] = @max_completion_tokens if @max_completion_tokens
    @last_payload_bytes = Oj.dump(body, mode: :compat).bytesize
    body
  end

  def format_payload_size
    return "" unless @last_payload_bytes

    bytes = @last_payload_bytes
    size = bytes >= 1_048_576 ? "#{(bytes / 1_048_576.0).round(2)} MB" : "#{(bytes / 1024.0).round(2)} KB"
    "(payload: #{size})"
  end

  def debug_request(body)
    warn "--- OpenAI request payload (Ruby hash) ---"
    pretty_messages = body[:messages].map do |msg|
      if msg[:content].is_a?(String)
        {role: msg[:role], content_lines: msg[:content].split("\n")}
      else
        msg
      end
    end
    warn Oj.dump(body.merge(messages: pretty_messages), mode: :compat,
      indent: 2)
    warn "--- end payload ---"
  end

  def debug_response(answer)
    warn "\n--- OpenAI response content ---"
    if answer
      if answer.is_a?(String)
        warn answer
      else
        warn Oj.dump(answer, mode: :compat, indent: 2)
      end
    else
      warn "(empty response)"
    end
    warn "--- end response ---\n"
  end

  def primary_api_error_endpoint
    "#{@api_base_url}/chat/completions"
  end

  def make_api_request(body)
    http = HTTPX.plugin(:proxy).with(
      timeout: {read_timeout: @request_timeout,
                write_timeout: @request_timeout},
      ssl: {verify_mode: OpenSSL::SSL::VERIFY_NONE},
      fallback_protocol: "http/1.1"
    )

    # Set up proxy if configured
    http = http.with_proxy(uri: @proxy_url) if @proxy_url && !@proxy_url.empty?

    http.post(primary_api_error_endpoint,
      headers: {
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{@api_key}"
      },
      body: Oj.dump(body, mode: :compat))
  end

  def handle_response_errors(response)
    return if response.status == 200
    return handle_error_response_without_status(response) if response.status.nil?

    handle_non_success_status(response)
  rescue NoMethodError
    handle_error_response_without_status(response)
  rescue HTTPX::Error => e
    if is_network_resource_error?(e.message.to_s)
      raise NetworkResourceError.new("Network/resource error: #{e.message}")
    end

    raise e
  end

  def handle_non_success_status(response)
    raise_rate_limit_error(response) if response.status == 429
    raise_server_error(response) if response.status >= 500 && response.status < 600

    error_message = extract_error_message_from_response(response)
    error_message ||= response.error.to_s if response.respond_to?(:error)
    error_message ||= response.message.to_s if response.respond_to?(:message)
    if error_message && is_network_resource_error?(error_message)
      raise NetworkResourceError.new("Network/resource error: #{error_message}")
    end

    if response&.body && is_network_resource_error?(response.body.to_s)
      raise NetworkResourceError.new("Network/resource error: #{response.body}")
    end

    pretty_print_error("API Error", response.status, ErrorResponseBody.format_body(response.body.to_s))
    exit 1
  end

  def raise_rate_limit_error(response)
    retry_after = extract_retry_after(response)
    raw = ErrorResponseBody.raw_body_from_http_response(response)
    error_message = extract_error_message_from_response(response)
    message = error_message ? "Rate limited by API: #{error_message}" : "Rate limited by API"

    if error_message&.include?("Insufficient balance") || error_message&.include?("no resource package")
      detail = [message, ErrorResponseBody.format_body(raw)].reject { |s| s.to_s.strip.empty? }.join("\n\n")
      pretty_print_error("API Error", response.status, detail)
      exit 1
    end

    raise RateLimitError.new(message, retry_after: retry_after, raw_body: raw)
  end

  def raise_server_error(response)
    raw = ErrorResponseBody.raw_body_from_http_response(response)
    raise ServerError.new("Server error", status: response.status, raw_body: raw)
  end

  def handle_error_response_without_status(response)
    if response.class.name == "HTTPX::ErrorResponse"
      err_msg = (response.error.to_s if response.respond_to?(:error) && response.error)
      err_msg ||= response.message.to_s if response.respond_to?(:message)
      if err_msg.to_s != "" && is_network_resource_error?(err_msg)
        raise NetworkResourceError.new("Network/resource error: #{err_msg}")
      end
    end

    error_status = extract_error_response_status(response)

    if error_status == 429
      error_message = extract_error_message_from_response_object(response)
      raw = ErrorResponseBody.raw_body_from_http_response(response)
      if error_message&.include?("Insufficient balance") || error_message&.include?("no resource package")
        error_details = format_error_response(response)
        pretty_print_error("API Error", error_status, error_details)
        exit 1
      end
      msg = error_message ? "Rate limited by API: #{error_message}" : "Rate limited by API"
      ra = extract_retry_after_from_error_response(response)
      raise RateLimitError.new(msg, retry_after: ra, raw_body: raw)
    end

    if error_status && error_status >= 500
      raw = ErrorResponseBody.raw_body_from_http_response(response)
      raise ServerError.new("Server error", status: error_status, raw_body: raw)
    end

    error_message = extract_error_message_from_response_object(response)
    error_message ||= response.error.to_s if response.respond_to?(:error)
    error_message ||= response.message.to_s if response.respond_to?(:message)

    if error_message && is_network_resource_error?(error_message)
      raise NetworkResourceError.new("Network/resource error: #{error_message}")
    end

    if response.respond_to?(:response) && response.response.respond_to?(:body) && response.response.body
      response_body = response.response.body.to_s
      if is_network_resource_error?(response_body)
        raise NetworkResourceError.new("Network/resource error: #{response_body}")
      end
    end

    error_details = format_error_response(response)
    pretty_print_error("API Error", "Unknown", error_details)
    exit 1
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

    retry_header = response.headers["retry-after"]&.first
    return nil unless retry_header

    Integer(retry_header)
  rescue ArgumentError
    nil
  end

  def extract_error_message_from_response(response)
    return nil unless response&.body

    parsed = Oj.load(response.body)
    return nil unless parsed.is_a?(Hash)

    parsed.dig("error", "message")
  rescue Oj::ParseError
    nil
  end

  def extract_error_message_from_response_object(response)
    return nil unless response.respond_to?(:response) && response.response.respond_to?(:body)

    parsed = Oj.load(response.response.body)
    return nil unless parsed.is_a?(Hash)

    parsed.dig("error", "message")
  rescue Oj::ParseError
    nil
  end

  def extract_error_response_status(response)
    return nil unless response.respond_to?(:response) && response.response
    return nil unless response.response.respond_to?(:status)

    response.response.status
  end

  def extract_answer(response)
    return nil unless response&.body

    parsed_response = Oj.load(response.body)
    return nil unless parsed_response.is_a?(Hash)

    answer = parsed_response.dig("choices", 0, "message", "content")

    # If content is empty or nil, try reasoning_content
    if answer.nil? || answer.empty?
      answer = parsed_response.dig("choices", 0, "message", "reasoning_content")
    end

    return answer unless answer.nil? || answer.empty?

    warn "No answer returned from OpenAI API. Full response body:"
    warn response.body
    exit 1
  end

  def fetch_env(key, default = nil)
    @env_vars ||= load_env_vars
    value = @env_vars.fetch(key, ENV[key] || default)
    return value unless value.nil?

    # Only require certain variables, make others optional
    required_vars = ["OPENAI_ACCESS_TOKEN"]
    if required_vars.include?(key)
      env_dir = script_directory
      env_path = File.join(env_dir, ".env")
      warn("Missing required environment variable: #{key}. Please add it to the .env file at #{env_path}.")
      exit 1
    end
    default
  end

  def ask_with_progress(messages, json: false, title: nil)
    with_openrouter_fallback(messages, json: json) do
      perform_progress_request(messages, json: json, title: title)
    end
  rescue Oj::ParseError => e
    handle_parse_error(e, response)
  end

  def setup_progress_tracking(messages, json: false, title: nil)
    total_size = [messages.to_s.bytesize, 6000].max
    progress_speed = load_progress_speed

    progressbar = create_progress_bar(total_size, title)
    start_time = Time.now

    set_progress_stop(false)
    progress_thread = start_progress_thread(progressbar, start_time, progress_speed, total_size)

    begin
      make_request_with_debug(messages, json: json)
    ensure
      finish_progress(progress_thread, progressbar, start_time, total_size)
    end
  end

  def make_request_with_debug(messages, json: false)
    retry_with_backoff do
      body = build_request_body(messages, json: json)
      debug_request(body) if @debug

      response = make_api_request(body)
      handle_response_errors(response)
      answer = extract_answer(response)
      debug_response(answer) if @debug
      answer
    end
  end

  def load_progress_speed
    return @progress_speed if defined?(@progress_speed)

    @progress_speed =
      File.exist?(PROGRESS_SPEED_FILE) ? File.read(PROGRESS_SPEED_FILE).to_f : DEFAULT_PROGRESS_SPEED
    @progress_speed = DEFAULT_PROGRESS_SPEED if @progress_speed <= 0
    @progress_speed
  rescue SystemCallError, ArgumentError
    @progress_speed = DEFAULT_PROGRESS_SPEED
  end

  def save_progress_speed(speed)
    File.write(PROGRESS_SPEED_FILE, speed.round(2).to_s)
  rescue SystemCallError
    # ignore persistence errors
  end

  def handle_http_error(error)
    error_message = error.message.to_s

    if is_network_resource_error?(error_message)
      raise NetworkResourceError.new("Network/resource error: #{error.message}")
    end

    error_type = case error
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

    pretty_print_error(error_type, "Network Error", error.message)
    exit 1
  end

  def handle_parse_error(error, response)
    warn "Failed to parse JSON response: #{error.message}"
    warn response.body if defined?(response) && response&.body
    exit 1
  end

  def create_progress_bar(total_size, title)
    ProgressBar.create(
      title: title || @progress_title,
      total: total_size,
      format: "%t: |%B| %p%% %e",
      length: 100
    )
  end

  def start_progress_thread(progressbar, start_time, progress_speed, total_size)
    Thread.new do
      run_progress_loop(progressbar, start_time, progress_speed, total_size)
    end
  end

  def run_progress_loop(progressbar, start_time, progress_speed, total_size)
    loop do
      break if progress_stopped?
      break unless update_progress_safely(progressbar, start_time, progress_speed, total_size)

      sleep 0.1
    end
  end

  def set_progress_stop(value)
    @progress_mutex.synchronize { @progress_stop = value }
  end

  def progress_stopped?
    @progress_mutex.synchronize { @progress_stop }
  end

  def update_progress_safely(progressbar, start_time, progress_speed, total_size)
    return false if progressbar.finished?

    elapsed_time = Time.now - start_time
    progress = (elapsed_time * progress_speed).round

    # Extend total when needed so percentage can count backwards then forward again
    adjust_progressbar_total(progressbar, progress, total_size)
    progressbar.progress = progress
    true
  rescue ProgressBar::InvalidProgressError
    # ProgressBar::InvalidProgressError: progress set after finish or invalid value
    warn "Progress update stopped due to progressbar state" if @debug
    false
  end

  def adjust_progressbar_total(progressbar, progress, total_size)
    return unless progress >= progressbar.total

    # Backwards counting: extend total so the displayed percentage drops (counts
    # backwards from 100%), then progress continues forward again. Avoids holding
    # at 100% when we don't know real response size and gives continuous feedback.
    progressbar.total += total_size
    # Rare case: when progress far exceeds total, adding initial size isn't enough
    progressbar.total = progress + 1 if progressbar.total <= progress
  end

  def finish_progress(progress_thread, progressbar, start_time, total_size)
    return unless progress_thread && progressbar

    set_progress_stop(true)
    # Give the thread a moment to exit cleanly before forcing termination
    progress_thread.join(0.5)
    progress_thread.kill if progress_thread.alive?

    finish_progressbar_safely(progressbar)
    save_progress_speed_from_elapsed(start_time, total_size)
  end

  def finish_progressbar_safely(progressbar)
    return if progressbar.finished?

    progressbar.progress = progressbar.total
    progressbar.finish
  rescue ProgressBar::InvalidProgressError
    # Progressbar already finished or in invalid state
  end

  def save_progress_speed_from_elapsed(start_time, total_size)
    elapsed_time = Time.now - start_time
    return unless elapsed_time.positive?

    # Use actual content size instead of inflated progressbar.progress
    # progressbar.progress may be inflated to provide continuous visual feedback
    actual_speed = total_size / elapsed_time
    save_progress_speed((load_progress_speed * 0.7) + (actual_speed * 0.3))
  end

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
    details.split("\n").each { |line| puts "│ #{line}" }

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
        "• Verify OPENAI_BASE_URL environment variable",
        "• Try using a different network"]
    when "API Error"
      ["• Check your API key (OPENAI_ACCESS_TOKEN)",
        "• Verify API quota and billing",
        "• Check if the model is available"]
    end
  end

end
