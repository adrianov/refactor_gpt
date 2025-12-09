#!/usr/bin/env ruby
# frozen_string_literal: true

require 'httpx'
require 'oj'

# Unified OpenAI client with proxy support for all GPT utilities
class OpenAiClient
  DEFAULT_MODEL = 'gpt-5.1'
  REQUEST_TIMEOUT = 100

  def initialize(model: DEFAULT_MODEL, debug: false, max_completion_tokens: nil)
    @api_base_url = fetch_env('OPENAI_BASE_URL')
    @api_key = fetch_env('OPENAI_ACCESS_TOKEN')
    @proxy_url = fetch_env('PROXY_URL', nil)
    @model = model
    @debug = debug
    @max_completion_tokens = max_completion_tokens
    @env_vars = nil
  end

  def ask(messages)
    body = build_request_body(messages)
    debug_request(body) if @debug

    response = make_api_request(body)
    handle_response_errors(response)
    extract_answer(response)
  rescue HTTPX::Error => e
    warn "HTTP request failed: #{e.class} - #{e.message}"
    exit 1
  rescue Oj::ParseError => e
    warn "Failed to parse JSON response: #{e.message}"
    warn response.body if defined?(response) && response&.body
    exit 1
  end

  private

  def build_request_body(messages)
    body = { model: @model, messages: messages }
    body[:max_completion_tokens] = @max_completion_tokens if @max_completion_tokens
    body
  end

  def debug_request(body)
    warn '--- OpenAI request payload (Ruby hash) ---'
    pretty_messages = body[:messages].map do |msg|
      if msg[:role] == 'system' && msg[:content].is_a?(String)
        { role: msg[:role], content_lines: msg[:content].split("\n") }
      else
        msg
      end
    end
    warn Oj.dump(body.merge(messages: pretty_messages), mode: :compat, indent: 2)
    warn '--- end payload ---'
  end

  def make_api_request(body)
    http = HTTPX.plugin(:proxy).with(
      timeout: { total_timeout: REQUEST_TIMEOUT },
      ssl: { verify_mode: OpenSSL::SSL::VERIFY_NONE }
    )

    # Set up proxy if configured
    http = http.with_proxy(uri: @proxy_url) if @proxy_url && !@proxy_url.empty?

    http.post("#{@api_base_url}/chat/completions",
              headers: {
                'Content-Type' => 'application/json',
                'Authorization' => "Bearer #{@api_key}"
              },
              body: Oj.dump(body, mode: :compat))
  end

  def handle_response_errors(response)
    return if response.status == 200

    warn "OpenAI API request failed with status #{response.status}"
    warn response.body
    exit 1
  rescue NoMethodError
    # Handle HTTPX::ErrorResponse which doesn't have status method
    warn "OpenAI API request failed: #{response.class}"
    warn "Error details: #{response.inspect}"
    exit 1
  end

  def extract_answer(response)
    answer = Oj.load(response.body).dig('choices', 0, 'message', 'content')
    return answer unless answer.nil? || answer.empty?

    warn 'No answer returned from OpenAI API. Full response body:'
    warn response.body
    exit 1
  end

  def fetch_env(key, default = nil)
    @env_vars ||= load_env_vars
    value = @env_vars.fetch(key, ENV[key] || default)
    return value unless value.nil?

    warn("Missing required environment variable: #{key}. Please add it to the .env file.")
    exit 1
  end

  def load_env_vars
    env_file_path = File.join(File.dirname(__FILE__), '.env')
    return {} unless File.exist?(env_file_path)

    File.foreach(env_file_path).with_object({}) do |line, h|
      key, value = line.split('=', 2)
      h[key.strip] = value.strip if key && value
    end
  end
end
