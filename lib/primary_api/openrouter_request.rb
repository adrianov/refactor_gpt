# frozen_string_literal: true

require "logger"

# Configures ruby-llm and builds OpenRouter chat requests.
module OpenrouterRequest
  private

  def build_ruby_llm_context
    proxy_url = PrimaryApiProxy.resolve(nil, load_env_vars)
    socks = proxy_url.to_s.match?(%r{\Asocks5://}i)
    if socks
      require "faraday/typhoeus"
      require_relative "streaming_compat"
      TyphoeusStreamingCompat.apply
    end
    RubyLLM.context { |config| apply_context_config(config, proxy_url, socks) }
  end

  def apply_context_config(config, proxy_url, socks)
    config.openrouter_api_key = @api_key
    config.openrouter_api_base = @api_base_url
    config.openai_use_system_role = true
    config.request_timeout = Integer(fetch_env("REQUEST_TIMEOUT", OpenrouterClient::REQUEST_TIMEOUT))
    config.max_retries = PrimaryApiErrors::MAX_RETRIES
    config.retry_interval = 5
    config.retry_backoff_factor = 2
    configure_transport(config, proxy_url, socks)
    config.log_file = $stderr
    config.log_level = Logger::DEBUG if @debug || ENV["RUBYLLM_DEBUG"]
  end

  def configure_transport(config, proxy_url, socks)
    config.http_proxy = proxy_url unless proxy_url.to_s.strip.empty?
    config.faraday_adapter = :typhoeus if socks
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
    params = json ? {response_format: {type: "json_object"}} : {}
    params[:max_completion_tokens] = @max_completion_tokens if @max_completion_tokens
    params.merge!(PromptCache.request_params(messages, model: @model, base_url: @api_base_url))
  end

  def seed_messages(chat, messages)
    PromptCache.cached_messages(messages, model: @model, base_url: @api_base_url).each do |message|
      chat.add_message(role: message_role(message), content: message_content(message))
    end
  end

  def message_role(message)
    (message[:role] || message["role"]).to_sym
  end

  def message_content(message)
    content = message[:content] || message["content"]
    content.is_a?(RubyLLM::Content::Raw) ? content : content.to_s
  end
end
