# frozen_string_literal: true

require "httpx"
require "oj"
require "ruby-progressbar"

# Unified OpenAI-compatible client with proxy support and OpenRouter fallback.
class OpenAiClient
  include AgentsFileHandler
  include PrimaryApiClient

  attr_reader :model
  DEFAULT_MODEL = "glm-5.2"
  REQUEST_TIMEOUT = 600
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
  end

  def ask_with_progress(messages, json: false, title: nil)
    with_openrouter_fallback(messages, json: json) do
      perform_progress_request(messages, json: json, title: title)
    end
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

  def is_network_resource_error?(error_message)
    msg = error_message.to_s
    msg.include?("resource_exhausted") || msg.match?(/connection\s+stalled/i) ||
      msg.include?("CANCEL") || msg.include?("canceled") ||
      msg.include?("stream closed") || msg.include?("closed with error") || msg.include?("0x8") ||
      msg.include?("SSL_read: unexpected eof while reading")
  end

  def build_request_body(messages, json: false)
    body = {model: @model, messages: messages}
    body[:response_format] = {type: "json_object"} if json
    body[:max_completion_tokens] = @max_completion_tokens if @max_completion_tokens
    @last_payload_bytes = Oj.dump(body, mode: :compat).bytesize
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
    warn Oj.dump(body.merge(messages: pretty_messages), mode: :compat, indent: 2)
    warn "--- end payload ---"
  end

  def debug_response(answer)
    warn "\n--- OpenAI response content ---"
    warn(answer ? (answer.is_a?(String) ? answer : Oj.dump(answer, mode: :compat, indent: 2)) : "(empty response)")
    warn "--- end response ---\n"
  end

  def primary_api_error_endpoint
    "#{@api_base_url}/chat/completions"
  end

  def make_api_request(body)
    http = HTTPX.plugin(:proxy).with(
      timeout: {read_timeout: @request_timeout, write_timeout: @request_timeout},
      ssl: PrimaryApiSsl.httpx_options,
      fallback_protocol: "http/1.1"
    )
    http = http.with_proxy(uri: @proxy_url) if @proxy_url && !@proxy_url.empty?
    http.post(primary_api_error_endpoint,
      headers: request_headers,
      body: Oj.dump(body, mode: :compat))
  end

  def request_headers
    {
      'Content-Type' => 'application/json',
      'Authorization' => "Bearer #{@api_key}"
    }.merge(OpenrouterHeaders.for_base_url(@api_base_url))
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

  def extract_answer(response)
    return nil unless response&.body

    parsed_response = Oj.load(response.body)
    return nil unless parsed_response.is_a?(Hash)

    answer = parsed_response.dig("choices", 0, "message", "content")
    answer = parsed_response.dig("choices", 0, "message", "reasoning_content") if answer.nil? || answer.empty?
    return answer unless answer.nil? || answer.empty?

    warn "No answer returned from OpenAI API. Full response body:"
    warn response.body
    exit 1
  end

  def fetch_env(key, default = nil)
    @env_vars ||= load_env_vars
    value = @env_vars.fetch(key, ENV[key] || default)
    return value unless value.nil?
    return default unless key == "OPENAI_ACCESS_TOKEN"

    env_path = File.join(script_directory, ".env")
    warn("Missing required environment variable: #{key}. Add it to #{env_path}.")
    exit 1
  end

  def make_request_with_debug(messages, json: false)
    response = nil
    retry_with_backoff do
      body = build_request_body(messages, json: json)
      debug_request(body) if @debug
      response = make_api_request(body)
      handle_response_errors(response)
      answer = extract_answer(response)
      debug_response(answer) if @debug
      answer
    end
  rescue Oj::ParseError => e
    handle_parse_error(e, response)
  end
end
