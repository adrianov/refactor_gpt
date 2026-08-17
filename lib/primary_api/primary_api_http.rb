# frozen_string_literal: true

require 'httpx'

# Builds HTTPX sessions for primary APIs: TLS, timeouts, and optional outbound proxy.
# Clears process HTTP(S)_PROXY during POST so HTTPX `URI#find_proxy` cannot replace `.env` SOCKS5.
module PrimaryApiHttp
  ENV_PROXY_KEYS = %w[HTTP_PROXY HTTPS_PROXY http_proxy https_proxy].freeze

  # HTTPX POST wrapper that ignores process HTTP proxy env.
  class Session
    def initialize(http)
      @http = http
    end

    def post(...)
      saved = {}
      ENV_PROXY_KEYS.each { |key| saved[key] = ENV.delete(key) if ENV.key?(key) }
      @http.post(...)
    ensure
      saved.each { |key, value| ENV[key] = value }
    end
  end

  module_function

  def build(timeout:, proxy_url: nil, stream: false)
    http = HTTPX.plugin(:proxy)
    http = http.plugin(:stream) if stream
    http = http.with(
      timeout: {read_timeout: timeout, write_timeout: timeout},
      ssl: PrimaryApiSsl.httpx_options,
      fallback_protocol: 'http/1.1'
    )
    proxy = PrimaryApiProxy.normalize(proxy_url)
    http = http.with_proxy(uri: proxy) unless proxy.empty?
    Session.new(http)
  end
end
