#!/usr/bin/env ruby
# frozen_string_literal: true

require "httpx"
require "oj"
require "ruby-progressbar"

# Custom error for rate limiting (429)
class RateLimitError < StandardError
  attr_reader :retry_after

  def initialize(message = "Rate limited", retry_after: nil)
    @retry_after = retry_after
    super(message)
  end
end

# Custom error for server errors (5xx)
class ServerError < StandardError
  attr_reader :status

  def initialize(message = "Server error", status: 500)
    @status = status
    super(message)
  end
end

# Unified OpenAI client with proxy support for all GPT utilities
class OpenAiClient
  DEFAULT_MODEL = "glm-4.6"
  REQUEST_TIMEOUT = 300
  DEFAULT_PROGRESS_SPEED = 300
  PROGRESS_SPEED_FILE = File.join(Dir.home, ".refactor_gpt").freeze

  def initialize(model: nil, debug: false, max_completion_tokens: nil,
    progress_title: nil)
    @api_base_url = fetch_env("OPENAI_BASE_URL", "https://api.openai.com/v1")
    @api_key = fetch_env("OPENAI_ACCESS_TOKEN")
    @proxy_url = fetch_env("PROXY_URL", nil)
    @model = model || fetch_env("DEFAULT_MODEL", DEFAULT_MODEL)
    @debug = debug
    @max_completion_tokens = max_completion_tokens
    @progress_title = progress_title
    @env_vars = nil
    @request_timeout = Integer(fetch_env("REQUEST_TIMEOUT", REQUEST_TIMEOUT))
    @progress_active = false
  end

  def ask(messages, json: false)
    return ask_with_progress(messages, json: json) if @progress_title

    retry_with_backoff do
      body = build_request_body(messages, json: json)
      debug_request(body) if @debug

      response = make_api_request(body)
      handle_response_errors(response)
      answer = extract_answer(response)
      debug_response(answer) if @debug
      answer
    end
  rescue HTTPX::Error => e
    handle_http_error(e)
  rescue Oj::ParseError => e
    handle_parse_error(e, response)
  end

  private

  def retry_with_backoff(max_retries: 3, base_delay: 1)
    retries = 0

    begin
      yield
    rescue HTTPX::Connection::HTTP2::GoawayError,
      HTTPX::TimeoutError,
      HTTPX::ConnectionError => e

      retries += 1
      if retries <= max_retries
        handle_retry_with_exponential_backoff(e, retries, max_retries, base_delay)
        retry
      else
        raise e
      end
    rescue RateLimitError => e
      retries += 1
      if retries <= max_retries
        handle_rate_limit_retry(e, retries, max_retries, base_delay)
        retry
      else
        warn "❌ Rate limit exceeded after #{max_retries} retries: #{e.message}"
        exit 1
      end
    rescue ServerError => e
      retries += 1
      if retries <= max_retries
        handle_server_error_retry(e, retries, max_retries, base_delay)
        retry
      else
        warn "❌ Server error persisted after #{max_retries} retries"
        exit 1
      end
    end
  end

  def handle_retry_with_exponential_backoff(error, retries, max_retries, base_delay)
    delay = base_delay * (2**(retries - 1))
    error_name = error.class.name.split("::").last
    warn "⚠️  Connection issue (#{error_name}), retrying in #{delay}s... (#{retries}/#{max_retries})"
    sleep(delay)
  end

  def handle_rate_limit_retry(error, retries, max_retries, base_delay)
    delay = error.retry_after || [30, base_delay * (4**(retries - 1))].max
    error_msg = error.message.include?("Rate limited by API:") ? error.message.split(": ", 2).last : nil
    base_msg = "⚠️  Rate limited (429)"
    msg = error_msg ? "#{base_msg}: #{error_msg}" : base_msg
    warn "#{msg}, retrying in #{delay}s... (#{retries}/#{max_retries})"
    sleep(delay)
  end

  def handle_server_error_retry(error, retries, max_retries, base_delay)
    delay = base_delay * (2**(retries - 1))
    warn "⚠️  Server error (#{error.status}), retrying in #{delay}s... (#{retries}/#{max_retries})"
    sleep(delay)
  end

  def build_request_body(messages, json: false)
    body = {model: @model, messages: messages}
    body[:response_format] = {type: "json_object"} if json
    body[:max_completion_tokens] = @max_completion_tokens if @max_completion_tokens
    body
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

  def make_api_request(body)
    http = HTTPX.plugin(:proxy).with(
      timeout: {read_timeout: @request_timeout,
                write_timeout: @request_timeout},
      ssl: {verify_mode: OpenSSL::SSL::VERIFY_NONE},
      fallback_protocol: "http/1.1"
    )

    # Set up proxy if configured
    http = http.with_proxy(uri: @proxy_url) if @proxy_url && !@proxy_url.empty?

    http.post("#{@api_base_url}/chat/completions",
      headers: {
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{@api_key}"
      },
      body: Oj.dump(body, mode: :compat))
  end

  def handle_response_errors(response)
    return if response.status == 200

    handle_non_success_status(response)
  rescue NoMethodError
    handle_error_response_without_status(response)
  end

  def handle_non_success_status(response)
    raise_rate_limit_error(response) if response.status == 429
    raise_server_error(response) if response.status >= 500 && response.status < 600

    pretty_print_error("API Error", response.status, response.body)
    exit 1
  end

  def raise_rate_limit_error(response)
    retry_after = extract_retry_after(response)
    error_message = extract_error_message_from_response(response)
    message = error_message ? "Rate limited by API: #{error_message}" : "Rate limited by API"

    if error_message&.include?("Insufficient balance") || error_message&.include?("no resource package")
      pretty_print_error("API Error", response.status, message)
      exit 1
    end

    raise RateLimitError.new(message, retry_after: retry_after)
  end

  def raise_server_error(response)
    raise ServerError.new("Server error", status: response.status)
  end

  def handle_error_response_without_status(response)
    error_status = extract_error_response_status(response)

    if error_status == 429
      error_message = extract_error_message_from_response_object(response)
      if error_message&.include?("Insufficient balance") || error_message&.include?("no resource package")
        error_details = format_error_response(response)
        pretty_print_error("API Error", error_status, error_details)
        exit 1
      end
      raise RateLimitError.new("Rate limited by API")
    end

    raise ServerError.new("Server error", status: error_status) if error_status && error_status >= 500

    error_details = format_error_response(response)
    pretty_print_error("API Error", "Unknown", error_details)
    exit 1
  end

  def extract_retry_after(response)
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
      warn("Missing required environment variable: #{key}. Please add it to the .env file.")
      exit 1
    end
    default
  end

  def ask_with_progress(messages, json: false)
    setup_progress_tracking(messages, json: json)
  rescue HTTPX::Error => e
    handle_http_error(e)
  rescue Oj::ParseError => e
    handle_parse_error(e, response)
  end

  def setup_progress_tracking(messages, json: false)
    return make_request_with_debug(messages, json: json) if @progress_active

    @progress_active = true
    total_size = [messages.to_s.bytesize, 6000].max
    progress_speed = load_progress_speed

    progressbar = create_progress_bar(total_size)
    start_time = Time.now
    progress_thread = start_progress_thread(progressbar, start_time, progress_speed, total_size)

    begin
      return make_request_with_debug(messages, json: json)
    ensure
      finish_progress(progress_thread, progressbar, start_time, total_size)
      @progress_active = false
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

  def create_progress_bar(total_size)
    ProgressBar.create(
      title: @progress_title,
      total: total_size,
      format: "%t: |%B| %p%% %e",
      length: 60
    )
  end

  def start_progress_thread(progressbar, start_time, progress_speed, total_size)
    Thread.new do
      loop do
        elapsed_time = Time.now - start_time
        progress = (elapsed_time * progress_speed).round

        # Allow progress to continue beyond 100% by gradually increasing total.
        # This provides better user experience than holding at 100% when we don't
        # know the real response speed, giving users continuous visual feedback.
        if progress >= progressbar.total
          # Add initial total size to get closer to 100% with each enhancement
          progressbar.total += total_size
          # Rare case: when progress far exceeds total, adding initial size isn't enough
          progressbar.total = progress + 1 if progressbar.total <= progress
        end
        progressbar.progress = progress

        sleep 0.1
      end
    rescue StandardError
      # Silently exit thread on any error
    end
  end

  def finish_progress(progress_thread, progressbar, start_time, total_size)
    return unless progress_thread && progressbar

    progress_thread.kill
    progressbar.progress = progressbar.total
    progressbar.finish

    # Save speed for next time
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

  def load_env_vars
    # First try project root (one level up from lib/)
    env_file_path = File.join(File.dirname(__dir__), ".env")

    # Fallback to current directory if not found
    env_file_path = File.join(Dir.pwd, ".env") unless File.exist?(env_file_path)

    return {} unless File.exist?(env_file_path)

    File.foreach(env_file_path).with_object({}) do |line, h|
      key, value = line.split("=", 2)
      h[key.strip] = value.strip if key && value
    end
  end
end
