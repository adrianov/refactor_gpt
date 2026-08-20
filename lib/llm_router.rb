# frozen_string_literal: true

# Routes model names to backend (Claude/OpenAI/Gemini) and returns base URL and access token.
# Use MODEL, TECHNICAL_MODEL, IMAGE_MODEL in .env; backend is detected from the model name.
module LlmRouter
  BACKENDS = {
    claude: { base_url_key: 'CLAUDE_BASE_URL', token_key: 'CLAUDE_ACCESS_TOKEN' },
    openai: { base_url_key: 'OPENAI_BASE_URL', token_key: 'OPENAI_ACCESS_TOKEN' },
    gemini: { base_url_key: 'GEMINI_BASE_URL', token_key: 'GEMINI_ACCESS_TOKEN' }
  }.freeze

  CLAUDE_PREFIX = /^claude-/i
  OPENAI_PREFIX = /^(gpt-|composer-|dall-e|openrouter\/)/i
  GEMINI_PREFIX = /^gemini-/i

  DEFAULT_CLAUDE_MODEL = 'claude-sonnet-4-6'
  DEFAULT_OPENAI_MODEL = 'gpt-5-nano'
  DEFAULT_GEMINI_MODEL = 'gemini-3.7-flash'

  def self.backend_for_model(name)
    return nil if name.nil? || name.to_s.strip.empty?

    n = name.to_s.strip
    return :claude if n.match?(CLAUDE_PREFIX)
    return :openai if n.match?(OPENAI_PREFIX)
    return :gemini if n.match?(GEMINI_PREFIX)

    nil
  end

  def self.config_for_model(name, env_vars = nil)
    env = env_vars || ENV
    model = name.to_s.strip
    backend = resolved_backend(model, env)
    return nil unless backend

    cfg = BACKENDS[backend]
    base_url = env[cfg[:base_url_key]]
    access_token = env[cfg[:token_key]]
    return nil if access_token.to_s.empty?

    base_url = default_base_url(backend) if base_url.to_s.empty?
    { backend: backend, base_url: base_url, access_token: access_token, model: model }
  end

  def self.resolved_backend(model, env)
    backend = backend_for_model(model)
    return :openai if backend == :gemini && !token_set?(env, 'GEMINI_ACCESS_TOKEN')

    backend
  end
  private_class_method :resolved_backend

  def self.default_base_url(backend)
    case backend
    when :claude then 'https://openrouter.ai/api/v1'
    when :openai then 'https://api.openai.com/v1'
    when :gemini then 'https://openrouter.ai/api/v1'
    else nil
    end
  end

  def self.model_from_env(env_vars = nil, key: 'MODEL')
    env = env_vars || ENV
    env[key].to_s.strip
  end

  def self.default_model(env_vars = nil)
    env = env_vars || ENV
    model = env['MODEL'].to_s.strip
    return model if token_set?(env, 'MODEL')

    return DEFAULT_CLAUDE_MODEL if token_set?(env, 'CLAUDE_ACCESS_TOKEN')
    return DEFAULT_GEMINI_MODEL if token_set?(env, 'GEMINI_ACCESS_TOKEN')

    if token_set?(env, 'OPENAI_ACCESS_TOKEN')
      from_env = env['DEFAULT_MODEL'].to_s.strip
      return from_env.empty? ? DEFAULT_OPENAI_MODEL : from_env
    end

    nil
  end

  def self.token_set?(env, key)
    v = env[key]
    v && !v.to_s.strip.empty?
  end

  def self.technical_model(env_vars = nil)
    env = env_vars || ENV
    tech = env['TECHNICAL_MODEL']
    (tech && !tech.to_s.strip.empty?) ? tech.to_s.strip : model_from_env(env, key: 'MODEL')
  end

  def self.image_model(env_vars = nil)
    model_from_env(env_vars || ENV, key: 'IMAGE_MODEL')
  end
end
