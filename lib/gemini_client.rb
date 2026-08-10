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


class GeminiClient
  include AgentsFileHandler
  include PrimaryApiBackoff
  include PrimaryApiErrorBody
  include PrimaryApiHttpErrors
  include ApiErrorDisplay
  include PrimaryApiProgress
  DEFAULT_MODEL = "gemini-3-flash"
  REQUEST_TIMEOUT = 600
  DEFAULT_PROGRESS_SPEED = 300
  PROGRESS_SPEED_FILE = File.join(Dir.home, ".gemini_gpt").freeze

  def initialize(model: nil, debug: false, max_completion_tokens: nil,
    progress_title: nil, api_base_url: nil, api_key: nil)
    @api_base_url = api_base_url || fetch_env("GEMINI_BASE_URL", "https://opencode.ai/zen/v1")
    @api_key = api_key || fetch_env("GEMINI_ACCESS_TOKEN")
    @proxy_url = fetch_env("PROXY_URL", nil)
    @model = model || fetch_env("GEMINI_MODEL", DEFAULT_MODEL)
    @debug = debug
    @max_completion_tokens = max_completion_tokens
    @progress_title = progress_title
    @env_vars = nil
    @request_timeout = Integer(fetch_env("REQUEST_TIMEOUT", REQUEST_TIMEOUT))
    @progress_mutex = Mutex.new
    @progress_stop = false
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

  def stream_answer(messages, json: false)
    reset_primary_error_body_warned!
    stream_primary_answer(messages, json: json) { |text| yield text }
  rescue RateLimitError, ServerError, NetworkResourceError => e
    stream_with_openrouter_fallback(messages, json: json, error: e) { |text| yield text }
  rescue HTTPX::Error => e
    stream_httpx_with_fallback(messages, json: json, error: e) { |text| yield text }
  end

  private

  def stream_primary_answer(messages, json: false)
    execute_with_network_retry do
      retry_with_backoff do
        body = build_request_body(messages, json: json)
        debug_request(body) if @debug

        response = raw_api_request(body)
        handle_response_errors(response)
        process_stream_body(response) { |text| yield text }
      end
    end
  end

  def stream_httpx_with_fallback(messages, json: false, error:)
    handle_http_error(error) unless is_network_resource_error?(error.message.to_s)

    stream_with_openrouter_fallback(
      messages,
      json: json,
      error: NetworkResourceError.new("Network/resource error: #{error.message}")
    ) { |text| yield text }
  end

  def stream_with_openrouter_fallback(messages, json: false, error:)
    warn_primary_api_error_body_once(error)
    answer = try_openrouter(messages, json: json)
    return answer.to_s.each_char { |char| yield char } if answer

    warn_primary_api_error_body_once(error)
    warn retry_failure_message(error)
    exit 1
  end

  def perform_request(messages, json: false)
    execute_with_network_retry do
      retry_with_backoff do
        body = build_request_body(messages, json: json)
        debug_request(body) if @debug

        response = raw_api_request(body)
        handle_response_errors(response)
        response = collect_streaming_response(response)
        answer = extract_answer(response)
        debug_response(answer) if @debug
        answer
      end
    end
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

    warn_primary_api_error_body_once(e)
    warn retry_failure_message(e)
    exit 1
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

  def format_payload_size
    return "" unless @last_payload_bytes

    bytes = @last_payload_bytes
    size = bytes >= 1_048_576 ? "#{(bytes / 1_048_576.0).round(2)} MB" : "#{(bytes / 1024.0).round(2)} KB"
    "(payload: #{size})"
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
    if fallback_configured?
      warn "#{message} Trying OpenRouter fallback..."
      raise error
    end

    warn message
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

  def process_stream_body(response)
    response.body.to_s.each_line do |line|
      text = parse_stream_line(line)
      yield text if text
    end
  rescue HTTPX::Error => e
    if is_network_resource_error?(e.message.to_s)
      raise NetworkResourceError.new("Network/resource error: #{e.message}")
    end
    handle_http_error(e)
  end

  def parse_stream_line(line)
    line = line.to_s.strip
    return nil if line.empty?

    json_str = line.start_with?("data: ") ? line.sub(/^data: /, "").strip : line
    return nil if json_str.empty? || ["[{", "]", ","].include?(json_str)

    chunk = Oj.load(json_str)
    extract_chunk_text(chunk)&.to_s
  rescue Oj::ParseError
    nil
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
      msg.include?("stream closed") || msg.include?("0x8")
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
    contents = convert_to_gemini_format(messages)

    body = {contents: contents}
    config = {generationConfig: {}}
    config[:generationConfig][:maxOutputTokens] = @max_completion_tokens if @max_completion_tokens

    if json
      config[:generationConfig][:responseMimeType] = "application/json"
    end

    config[:generationConfig][:temperature] = 0.7

    merged = body.merge(config)
    @last_payload_bytes = Oj.dump(merged, mode: :compat).bytesize
    merged
  end

  def convert_to_gemini_format(messages)
    contents = []

    messages.each do |msg|
      role = (msg[:role] == "assistant") ? "model" : msg[:role]
      text = msg[:content]

      contents << {
        role: role,
        parts: [{text: text}]
      }
    end

    contents
  end

  def debug_request(body)
    warn "--- Gemini request payload (Ruby hash) ---"
    warn Oj.dump(body, mode: :compat, indent: 2)
    warn "--- end payload ---"
  end

  def debug_response(answer)
    warn "\n--- Gemini response content ---"
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
    "#{@api_base_url}/models/#{@model}:streamGenerateContent"
  end

  def raw_api_request(body)
    http = HTTPX.plugin(:proxy).with(
      timeout: {read_timeout: @request_timeout,
                write_timeout: @request_timeout},
      ssl: {verify_mode: OpenSSL::SSL::VERIFY_NONE},
      fallback_protocol: "http/1.1"
    )

    http = http.with_proxy(uri: @proxy_url) if @proxy_url && !@proxy_url.empty?

    http.post(primary_api_error_endpoint,
      headers: {
        "Content-Type" => "application/json",
        "x-goog-api-key" => @api_key
      },
      body: Oj.dump(body, mode: :compat))
  end

  def collect_streaming_response(response)
    return response unless response.status == 200

    chunks = []
    response.body.to_s.each_line do |line|
      chunk = parse_stream_line_to_json(line)
      chunks << chunk if chunk
    end

    build_combined_response(chunks, response)
  rescue HTTPX::Error => e
    handle_http_error(e)
  end

  def parse_stream_line_to_json(line)
    line = line.to_s.strip
    return nil if line.empty?

    json_str = line.start_with?("data: ") ? line.sub(/^data: /, "").strip : line
    return nil if json_str.empty? || ["[{", "]", ","].include?(json_str)

    Oj.load(json_str)
  rescue Oj::ParseError
    nil
  end

  def build_combined_response(chunks, original_response)
    return original_response if chunks.empty?

    last_chunk = chunks.last
    combined_text = chunks.map do |chunk|
      chunk.dig("candidates", 0, "content", "parts", 0, "text")
    end.compact.join

    usage = last_chunk.is_a?(Hash) ? last_chunk["usageMetadata"] : nil
    combined_body = {
      "candidates" => [
        {
          "content" => {
            "role" => "model",
            "parts" => [{"text" => combined_text}]
          },
          "finishReason" => last_chunk.dig("candidates", 0, "finishReason")
        }
      ],
      "usageMetadata" => usage.is_a?(Hash) ? usage : nil
    }

    MockResponse.new(200, Oj.dump(combined_body, mode: :compat))
  end

  class MockResponse
    attr_reader :status, :body

    def initialize(status, body)
      @status = status
      @body = body
    end
  end

  def handle_response_errors(response)
    return if response.status == 200

    handle_non_success_status(response)
  rescue NoMethodError
    handle_error_response_without_status(response)
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

    candidate = parsed_response.dig("candidates", 0)
    return nil unless candidate

    content = candidate.dig("content", "parts", 0, "text")

    return content unless content.nil? || content.empty?

    warn "No answer returned from Gemini API. Full response body:"
    warn response.body
    exit 1
  end

  def extract_chunk_text(chunk)
    chunk.dig("candidates", 0, "content", "parts", 0, "text")
  end

  def fetch_env(key, default = nil)
    @env_vars ||= load_env_vars
    value = @env_vars.fetch(key, ENV[key] || default)
    return value unless value.nil?

    required_vars = ["GEMINI_ACCESS_TOKEN"]
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

  def make_request_with_debug(messages, json: false)
    retry_with_backoff do
      body = build_request_body(messages, json: json)
      debug_request(body) if @debug

      response = raw_api_request(body)
      handle_response_errors(response)
      response = collect_streaming_response(response)
      answer = extract_answer(response)
      debug_response(answer) if @debug
      answer
    end
  end

  def error_suggestions(error_type)
    case error_type
    when "Connection Failed"
      ["• Check your internet connection", "• Try again later", "• Verify API endpoint"]
    when "Request Timeout"
      ["• Request too large", "• Try shorter prompt", "• Check REQUEST_TIMEOUT"]
    when "DNS Resolution Failed"
      ["• Check DNS settings", "• Verify GEMINI_BASE_URL", "• Try different network"]
    when "API Error"
      ["• Check GEMINI_ACCESS_TOKEN", "• Verify API quota", "• Check model availability"]
    else
      super
    end
  end
end
