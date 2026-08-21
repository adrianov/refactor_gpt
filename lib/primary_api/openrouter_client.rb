# frozen_string_literal: true

require "httpx"
require "oj"
require "ruby-progressbar"

# OpenRouter chat client with outbound proxy support, prompt cache markers, retries, and progress UI.
class OpenrouterClient
  include AgentsFileHandler
  include PrimaryApiClient

  attr_reader :model
  DEFAULT_BASE_URL = "https://openrouter.ai/api/v1"
  DEFAULT_MODEL = "stealth/ox-alpha"
  REQUEST_TIMEOUT = 600
  DEFAULT_PROGRESS_SPEED = 300
  PROGRESS_SPEED_FILE = File.join(Dir.home, ".refactor_gpt").freeze

  # Resolves MODEL from the app .env (file wins over process env), falling back to the default model.
  def self.default_model(env_vars = nil)
    env = env_vars || ENV.to_h.merge(Utility.load_env_vars)
    model = env["MODEL"].to_s.strip
    model.empty? ? DEFAULT_MODEL : model
  end

  def initialize(model: nil, debug: false, max_completion_tokens: nil,
    progress_title: nil, api_base_url: nil, api_key: nil, raise_on_server_error: false,
    reasoning: nil)
    @api_base_url = api_base_url || fetch_env("OPENROUTER_BASE_URL", DEFAULT_BASE_URL)
    @api_key = api_key || fetch_env("OPENROUTER_API_KEY")
    @proxy_url = resolve_proxy_url
    @model = model || fetch_env("MODEL", DEFAULT_MODEL)
    @debug = debug
    @max_completion_tokens = max_completion_tokens
    @reasoning = reasoning
    @progress_title = progress_title
    @env_vars = nil
    @request_timeout = Integer(fetch_env("REQUEST_TIMEOUT", REQUEST_TIMEOUT))
    @progress_mutex = Mutex.new
    @progress_stop = false
    @raise_on_server_error = raise_on_server_error
  end

  def ask(messages, json: false, title: nil)
    title ||= @progress_title
    title ? perform_progress_request(messages, json: json, title: title) : perform_request(messages, json: json)
  end

  def ask_with_progress(messages, json: false, title: nil)
    perform_progress_request(messages, json: json, title: title)
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
    body[:reasoning] = @reasoning if @reasoning
    PromptCache.apply!(body, model: @model, base_url: @api_base_url)
    @last_payload_bytes = Oj.dump(body, mode: :compat).bytesize
    body
  end

  def debug_request(body)
    warn "--- OpenRouter request payload (Ruby hash) ---"
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
    warn "\n--- OpenRouter response content ---"
    warn(answer ? (answer.is_a?(String) ? answer : Oj.dump(answer, mode: :compat, indent: 2)) : "(empty response)")
    warn "--- end response ---\n"
  end

  def primary_api_error_endpoint
    "#{@api_base_url}/chat/completions"
  end

  def make_api_request(body)
    PrimaryApiHttp.build(timeout: @request_timeout, proxy_url: @proxy_url).post(
      primary_api_error_endpoint,
      headers: request_headers,
      body: Oj.dump(body, mode: :compat)
    )
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

  def extract_answer(response, json: false)
    answer = CompletionAnswer.from_body(response&.body)
    if json && answer && !OpenrouterJson.valid?(answer)
      answer = OpenrouterJson.extract_from_text(answer) || answer
    end
    return answer unless answer.nil? || answer.empty?

    warn "No answer returned from OpenRouter API. Full response body:"
    warn response.body
    exit 1
  end

  def fetch_env(key, default = nil)
    @env_vars ||= load_env_vars
    value = @env_vars.fetch(key, ENV[key] || default)
    return value unless value.nil?
    return default unless key == "OPENROUTER_API_KEY"

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
      answer = extract_answer(response, json: json)
      debug_response(answer) if @debug
      answer
    end
  rescue Oj::ParseError => e
    handle_parse_error(e, response)
  end

  def raise_on_server_error?
    @raise_on_server_error
  end
end
