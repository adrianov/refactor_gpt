# frozen_string_literal: true

require "openssl"

# Shared HTTPX SSL settings for primary API and OpenRouter clients.
# VERIFY_PEER by default; set SSL_CERT_FILE / SSL_CERT_DIR for a custom CA (e.g. corporate proxy).
module PrimaryApiSsl
  module_function

  def httpx_options
    options = {verify_mode: OpenSSL::SSL::VERIFY_PEER}
    ca_file = ENV["SSL_CERT_FILE"].to_s
    ca_path = ENV["SSL_CERT_DIR"].to_s
    options[:ca_file] = ca_file unless ca_file.empty?
    options[:ca_path] = ca_path unless ca_path.empty?
    options
  end
end
