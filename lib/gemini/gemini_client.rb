# frozen_string_literal: true

require "httpx"
require "oj"
require "ruby-progressbar"

# Gemini generateContent / streamGenerateContent client with OpenRouter fallback.
class GeminiClient
  include AgentsFileHandler
  include PrimaryApiClient
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
    @content_stream = GeminiContentStream.new(max_completion_tokens: max_completion_tokens)
    @openrouter_client = build_openrouter_client
  end

  def ask(messages, json: false, title: nil)
    title ||= @progress_title
    with_openrouter_fallback(messages, json: json) do
      title ? perform_progress_request(messages, json: json, title: title) : perform_request(messages, json: json)
    end
  end

  def stream_answer(messages, json: false)
    reset_primary_error_body_warned!
    stream_primary_answer(messages, json: json) { |text| yield text }
  rescue *PrimaryApiFallback::FALLBACK_ERRORS => e
    stream_openrouter(messages, json: json, error: e) { |text| yield text }
  rescue HTTPX::Error => e
    stream_httpx_fallback(messages, json: json, error: e) { |text| yield text }
  end

  def ask_with_progress(messages, json: false, title: nil)
    with_openrouter_fallback(messages, json: json) do
      perform_progress_request(messages, json: json, title: title)
    end
  end

  private

  def stream_primary_answer(messages, json: false)
    execute_with_network_retry do
      retry_with_backoff do
        body = build_request_body(messages, json: json)
        debug_request(body) if @debug
        response = raw_api_request(body, stream: true)
        handle_response_errors(response)
        @content_stream.each_text_chunk(response) { |text| yield text }
      end
    end
  end

  def stream_httpx_fallback(messages, json: false, error:)
    handle_http_error(error) unless is_network_resource_error?(error.message.to_s)
    stream_openrouter(
      messages, json: json,
      error: NetworkResourceError.new("Network/resource error: #{error.message}")
    ) { |text| yield text }
  end

  def stream_openrouter(messages, json: false, error:)
    warn_primary_api_error_body_once(error)
    answer = try_openrouter(messages, json: json)
    return answer.to_s.each_char { |char| yield char } if answer

    handle_openrouter_failure(error)
  end

  def perform_request(messages, json: false)
    execute_with_network_retry { retry_with_backoff { request_answer(messages, json: json) } }
  rescue HTTPX::Error => e
    raise_or_handle_httpx(e)
  end

  def perform_progress_request(messages, json: false, title: nil)
    execute_with_network_retry { setup_progress_tracking(messages, json: json, title: title) }
  rescue HTTPX::Error => e
    raise_or_handle_httpx(e)
  end

  def raise_or_handle_httpx(error)
    if is_network_resource_error?(error.message.to_s)
      raise NetworkResourceError, "Network/resource error: #{error.message}"
    end

    handle_http_error(error)
  end

  def is_network_resource_error?(error_message)
    msg = error_message.to_s
    msg.include?("resource_exhausted") || msg.match?(/connection\s+stalled/i) ||
      msg.include?("CANCEL") || msg.include?("canceled") ||
      msg.include?("stream closed") || msg.include?("0x8")
  end

  def build_request_body(messages, json: false)
    body = @content_stream.build_body(messages, json: json)
    @last_payload_bytes = @content_stream.last_payload_bytes
    body
  end

  def debug_request(body)
    warn "--- Gemini request payload ---\n#{Oj.dump(body, mode: :compat, indent: 2)}\n--- end payload ---"
  end

  def debug_response(answer)
    body = answer.is_a?(String) ? answer : (answer ? Oj.dump(answer, mode: :compat, indent: 2) : "(empty response)")
    warn "\n--- Gemini response ---\n#{body}\n--- end response ---\n"
  end

  def primary_api_error_endpoint
    "#{@api_base_url}/models/#{@model}:streamGenerateContent?alt=sse"
  end

  def raw_api_request(body, stream: false)
    http = HTTPX.plugin(:proxy)
    http = http.plugin(:stream) if stream
    http = http.with(
      timeout: {read_timeout: @request_timeout, write_timeout: @request_timeout},
      ssl: PrimaryApiSsl.httpx_options,
      fallback_protocol: "http/1.1"
    )
    http = http.with_proxy(uri: @proxy_url) if @proxy_url && !@proxy_url.empty?
    params = {
      headers: {"Content-Type" => "application/json", "x-goog-api-key" => @api_key},
      body: Oj.dump(body, mode: :compat)
    }
    params[:stream] = true if stream
    http.post(primary_api_error_endpoint, **params)
  end

  def handle_response_errors(response)
    return if response.status == 200

    handle_non_success_status(response)
  rescue NoMethodError
    handle_error_response_without_status(response)
  end

  def fetch_env(key, default = nil)
    @env_vars ||= load_env_vars
    value = @env_vars.fetch(key, ENV[key] || default)
    return value unless value.nil?
    return default unless key == "GEMINI_ACCESS_TOKEN"

    warn("Missing required environment variable: #{key}. Add it to #{File.join(script_directory, ".env")}.")
    exit 1
  end

  def make_request_with_debug(messages, json: false)
    retry_with_backoff { request_answer(messages, json: json) }
  end

  def request_answer(messages, json: false)
    response = nil
    body = build_request_body(messages, json: json)
    debug_request(body) if @debug
    response = raw_api_request(body)
    handle_response_errors(response)
    answer = @content_stream.extract_answer(@content_stream.assemble(response))
    debug_response(answer) if @debug
    answer
  rescue HTTPX::Error => e
    handle_http_error(e)
  rescue Oj::ParseError => e
    handle_parse_error(e, response)
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
