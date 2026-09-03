# frozen_string_literal: true

require 'ruby_llm'

# OpenRouter chat client built on ruby-llm with isolated request context.
class OpenrouterClient
  include AgentsFileHandler
  include OpenrouterRequest
  include OpenrouterResponse
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
    @model = normalize_model(model || fetch_env('MODEL', DEFAULT_MODEL))
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

  # OpenRouter takes bare slugs; an "openrouter/" prefix is client-side routing only.
  def normalize_model(id)
    id.to_s.sub(%r{\Aopenrouter/}, '')
  end

  def fetch_env(key, default = nil)
    value = load_env_vars.fetch(key, ENV[key] || default)
    return value unless value.nil?
    return default unless key == 'OPENROUTER_API_KEY'

    warn("Missing required environment variable: #{key}. Add it to #{File.join(script_directory, '.env')}.")
    exit 1
  end

end
