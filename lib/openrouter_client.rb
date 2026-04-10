# frozen_string_literal: true

require "httpx"
require "oj"

# OpenRouter fallback client for primary provider outages and rate limits.
class OpenrouterClient
  DEFAULT_BASE_URL = "https://openrouter.ai/api/v1".freeze
  DEFAULT_MODEL = "openrouter/auto".freeze
  RETRY_DELAYS = [5, 10, 30].freeze

  def initialize(api_key:, api_base_url: nil, model: nil, proxy_url: nil, request_timeout: 300, debug: false)
    @api_key = api_key
    @api_base_url = api_base_url.to_s.strip.empty? ? DEFAULT_BASE_URL : api_base_url
    @model = model.to_s.strip.empty? ? DEFAULT_MODEL : model
    @proxy_url = proxy_url
    @request_timeout = request_timeout
    @debug = debug
  end

  def configured?
    !@api_key.to_s.strip.empty?
  end

  def ask(messages, json: false, max_completion_tokens: nil, source_model: nil)
    return nil unless configured?

    body = build_request_body(messages, json: json, max_completion_tokens: max_completion_tokens)
    debug_request(body, source_model) if @debug

    response = post_with_retry(body)
    return warn_failure(response) unless response.status == 200

    answer = extract_answer(response)
    debug_response(answer) if @debug
    answer
  rescue HTTPX::Error, Oj::ParseError => e
    warn "⚠️  OpenRouter fallback failed: #{e.message}"
    nil
  end

  private

  def build_request_body(messages, json: false, max_completion_tokens: nil)
    body = {
      model: @model,
      messages: normalize_messages(messages)
    }
    body[:response_format] = {type: "json_object"} if json
    body[:max_tokens] = max_completion_tokens if max_completion_tokens
    body
  end

  def normalize_messages(messages)
    messages.map do |message|
      {
        role: message[:role] || message["role"],
        content: message[:content] || message["content"]
      }
    end
  end

  def post_with_retry(body)
    response = make_api_request(body)
    RETRY_DELAYS.each_with_index do |delay, index|
      return response unless retryable?(response)

      warn "⚠️  OpenRouter fallback retrying in #{delay}s... (#{index + 1}/#{RETRY_DELAYS.size})"
      sleep(delay)
      response = make_api_request(body)
    end
    response
  end

  def retryable?(response)
    status = response.status.to_i
    status == 429 || (status >= 500 && status < 600)
  end

  def make_api_request(body)
    http = HTTPX.plugin(:proxy).with(
      timeout: {read_timeout: @request_timeout, write_timeout: @request_timeout},
      ssl: {verify_mode: OpenSSL::SSL::VERIFY_NONE},
      fallback_protocol: "http/1.1"
    )
    http = http.with_proxy(uri: @proxy_url) if @proxy_url && !@proxy_url.empty?

    http.post(endpoint,
      headers: {
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{@api_key}"
      },
      body: Oj.dump(body, mode: :compat))
  end

  def endpoint
    return @api_base_url if @api_base_url.end_with?("/chat/completions")

    "#{@api_base_url}/chat/completions"
  end

  def extract_answer(response)
    parsed_response = Oj.load(response.body)
    answer = parsed_response.dig("choices", 0, "message", "content")
    return answer unless answer.nil? || answer.empty?

    warn_failure(response)
  end

  def warn_failure(response)
    status = response&.status || "Unknown"
    raw = response&.body.to_s
    warn "⚠️  OpenRouter fallback failed (#{status})"
    ErrorResponseBody.warn_if_present("", raw)
    nil
  end

  def debug_request(body, source_model)
    warn "--- OpenRouter fallback request (source=#{source_model || 'unknown'}) ---"
    warn Oj.dump(body, mode: :compat, indent: 2)
    warn "--- end OpenRouter request ---"
  end

  def debug_response(answer)
    warn "\n--- OpenRouter fallback response ---"
    warn answer.to_s.empty? ? "(empty response)" : answer
    warn "--- end OpenRouter response ---\n"
  end
end
