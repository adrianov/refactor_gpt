# frozen_string_literal: true

require 'httpx'

# Builds HTTPX sessions for primary APIs: TLS, timeouts, and optional outbound proxy.
module PrimaryApiHttp
  module_function

  def build(timeout:, proxy_url: nil, stream: false)
    http = HTTPX.plugin(:proxy)
    http = http.plugin(:stream) if stream
    http = http.with(
      timeout: {read_timeout: timeout, write_timeout: timeout},
      ssl: PrimaryApiSsl.httpx_options,
      fallback_protocol: 'http/1.1'
    )
    proxy = PrimaryApiProxy.resolve(proxy_url)
    return http if proxy.nil? || proxy.empty?

    http.with_proxy(uri: proxy)
  end
end
