# frozen_string_literal: true

require 'ruby_llm'
require 'logger'
require 'oj'

# OpenRouter chat client built on ruby-llm: per-instance context (API key, base URL, SOCKS5
# proxy, timeout, retries), prompt-cache markers, streamed progress UI, JSON mode, and
# balance-exhaustion hard exit.
class OpenrouterClient
  include AgentsFileHandler
  include PrimaryApiErrors

  attr_reader :model
  DEFAULT_BASE_URL = 'https://openrouter.ai/api/v1'
  DEFAULT_MODEL = 'stealth/ox-alpha'
  REQUEST_TIMEOUT = 600

  class << self
    # Resolves MODEL from the app .env (file wins over process env), falling back to the default model.
    def default_model(env_vars = nil)
      env = env_vars || ENV.to_h.merge(Utility.load_env_vars)
      model = env['MODEL'].to_s.strip
      model.empty? ? DEFAULT_MODEL : model
    end
  end

  def initialize(model: nil, debug: false, max_completion_tokens: nil,
    progress_title: nil, api_base_url: nil, api_key: nil, raise_on_server_error: false,
    reasoning: nil)
    @model = model || fetch_env('MODEL', DEFAULT_MODEL)
    @api_base_url = api_base_url || fetch_env('OPENROUTER_BASE_URL', DEFAULT_BASE_URL)
    @api_key = api_key || fetch_env('OPENROUTER_API_KEY')
    @debug = debug
    @max_completion_tokens = max_completion_tokens
    @reasoning = reasoning
    @raise_on_server_error = raise_on_server_error
    @progress_title = progress_title
    @context = build_ruby_llm_context
  end

  def ask(messages, json: false, title: nil)
    run(messages, json: json, title: title || @progress_title)
  end

  private

  def run(messages, json:, title:)
    chat = build_chat(messages, json: json)
    message = translate_api_errors do
      complete_with_upstream_retries do
        title ? complete_streamed(chat, messages, title) : chat.complete
      end
    end
    answer = ensure_answer!(json_fallback(answer_from(message), json: json), message)
    debug_response(answer) if @debug
    answer
  end

  def build_ruby_llm_context
    proxy_url = PrimaryApiProxy.resolve(nil, load_env_vars)
    socks = proxy_url.to_s.match?(%r{\Asocks5://}i)
    if socks
      require 'faraday/typhoeus'
      require_relative 'streaming_compat'
      TyphoeusStreamingCompat.apply
    end
    RubyLLM.context { |config| apply_context_config(config, proxy_url, socks) }
  end

  # Per-instance isolation: key, base URL, timeout, proxy, and adapter apply to this client only.
  def apply_context_config(config, proxy_url, socks)
    config.openrouter_api_key = @api_key
    config.openrouter_api_base = @api_base_url
    config.openai_use_system_role = true
    configure_timeouts(config)
    configure_retries(config)
    configure_transport(config, proxy_url, socks)
    config.log_file = $stderr
    config.log_level = Logger::DEBUG if @debug || ENV['RUBYLLM_DEBUG']
  end

  def configure_timeouts(config)
    config.request_timeout = Integer(fetch_env('REQUEST_TIMEOUT', REQUEST_TIMEOUT))
  end

  # SOCKS5 proxies need typhoeus; Net::HTTP cannot speak socks5://.
  def configure_transport(config, proxy_url, socks)
    config.http_proxy = proxy_url unless proxy_url.to_s.strip.empty?
    config.faraday_adapter = :typhoeus if socks
  end

  def configure_retries(config)
    config.max_retries = PrimaryApiErrors::MAX_RETRIES
    config.retry_interval = 5
    config.retry_backoff_factor = 2
  end

  def build_chat(messages, json: false)
    chat = @context.chat(model: @model, provider: :openrouter, assume_model_exists: true)
    chat.with_headers(**OpenrouterHeaders.for_base_url(@api_base_url))
    params = request_params(messages, json: json)
    chat.with_params(**params) unless params.empty?
    chat.with_thinking(**@reasoning) if @reasoning
    seed_messages(chat, messages)
    debug_request(messages, params) if @debug
    chat
  end

  def request_params(messages, json:)
    params = { response_format: { type: 'json_object' } } if json
    params ||= {}
    params[:max_completion_tokens] = @max_completion_tokens if @max_completion_tokens
    params.merge!(PromptCache.request_params(messages, model: @model, base_url: @api_base_url))
    params
  end

  def seed_messages(chat, messages)
    PromptCache.cached_messages(messages, model: @model, base_url: @api_base_url).each do |message|
      chat.add_message(role: message_role(message), content: message_content(message))
    end
  end

  def complete_streamed(chat, messages, title)
    bar = PrimaryApiProgress.create(title: title, estimate_bytes: messages.to_s.bytesize)
    received = 0
    chat.complete do |chunk|
      delta = chunk.content.to_s
      next if delta.empty?

      received += delta.bytesize
      PrimaryApiProgress.record(bar, received)
    end
  ensure
    PrimaryApiProgress.finish(bar)
  end

  def message_role(message)
    (message[:role] || message['role']).to_sym
  end

  def message_content(message)
    content = message[:content] || message['content']
    content.is_a?(RubyLLM::Content::Raw) ? content : content.to_s
  end

  # Some hosts put the reply in reasoning when content is null.
  def answer_from(message)
    text = message.content.is_a?(String) ? message.content : message.content.to_s
    return text unless text.strip.empty?
    return message.thinking.text.to_s if message.thinking&.text

    text
  end

  def json_fallback(answer, json:)
    return answer unless json && !OpenrouterJson.valid?(answer)

    OpenrouterJson.extract_from_text(answer) || answer
  end

  def ensure_answer!(answer, message)
    return answer unless answer.nil? || answer.strip.empty?

    warn 'No answer returned from OpenRouter API. Full response body:'
    warn format_body(error_body(message))
    exit 1
  end

  def fetch_env(key, default = nil)
    value = load_env_vars.fetch(key, ENV[key] || default)
    return value unless value.nil?
    return default unless key == 'OPENROUTER_API_KEY'

    warn("Missing required environment variable: #{key}. Add it to #{File.join(script_directory, '.env')}.")
    exit 1
  end

  def debug_request(messages, params)
    warn "--- OpenRouter request payload (#{primary_api_error_endpoint}) ---"
    summary = messages.map do |msg|
      content = message_content(msg)
      content.is_a?(String) ? { role: message_role(msg), content_lines: content.split("\n") } : msg
    end
    warn Oj.dump({ model: @model, params: params, messages: summary }, mode: :compat, indent: 2)
    warn '--- end payload ---'
  end
  def debug_response(answer)
    warn "\n--- OpenRouter response content ---"
    warn answer
    warn "--- end response ---\n"
  end
end
