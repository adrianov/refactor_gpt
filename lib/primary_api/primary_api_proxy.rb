# frozen_string_literal: true

# Chooses an outbound proxy URL for API clients from PROXY_URL and common proxy env vars.
# When several values are present, SOCKS5 wins; socks:// and socks5h:// become socks5://.
module PrimaryApiProxy
  CANDIDATE_KEYS = %w[
    PROXY_URL
    ALL_PROXY all_proxy
    SOCKS5_PROXY SOCKS_PROXY socks5_proxy socks_proxy
    HTTPS_PROXY https_proxy
    HTTP_PROXY http_proxy
  ].freeze

  module_function

  def resolve(explicit = nil, env = ENV)
    values = []
    values << explicit unless blank?(explicit)
    CANDIDATE_KEYS.each do |key|
      value = env_value(env, key)
      values << value unless blank?(value)
    end
    choose(values)
  end

  def normalize(url)
    url.to_s.strip
      .sub(/\Asocks:\/\//i, 'socks5://')
      .sub(/\Asocks5h:\/\//i, 'socks5://')
  end

  def choose(urls)
    normalized = urls.filter_map do |url|
      value = normalize(url)
      value unless value.empty?
    end.uniq
    normalized.find { |url| url.match?(%r{\Asocks5://}i) } || normalized.first
  end

  def blank?(value)
    value.nil? || value.to_s.strip.empty?
  end

  def env_value(env, key)
    return env[key] if env.key?(key)

    env[key.to_s] if env.respond_to?(:key?) && env.key?(key.to_s)
  end
end
