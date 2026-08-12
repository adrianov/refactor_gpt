# frozen_string_literal: true

require "httpx"
require "oj"

# OpenAI-compatible client aimed at OpenRouter (also reused for REFACTOR API failover), with prompt cache markers.
class OpenrouterClient
  DEFAULT_BASE_URL = "https://openrouter.ai/api/v1".freeze
  DEFAULT_MODEL = "openrouter/auto".freeze
  RETRY_DELAYS = [5, 10, 30].freeze

  def initialize(api_key:, api_base_url: nil, model: nil, proxy_url: nil, request_timeout: 600, debug: false)
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
    answer = handle_json_response(answer, messages, max_completion_tokens) if json && answer

    debug_response(answer) if @debug
    answer
  rescue StandardError => e
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
    PromptCache.apply!(body, model: @model, base_url: @api_base_url)
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
    PrimaryApiHttp.build(timeout: @request_timeout, proxy_url: @proxy_url).post(
      endpoint,
      headers: request_headers,
      body: Oj.dump(body, mode: :compat)
    )
  end

  def request_headers
    {
      'Content-Type' => 'application/json',
      'Authorization' => "Bearer #{@api_key}"
    }.merge(OpenrouterHeaders.for_base_url(@api_base_url))
  end

  def endpoint
    return @api_base_url if @api_base_url.end_with?("/chat/completions")

    "#{@api_base_url}/chat/completions"
  end

  def extract_answer(response)
    answer = message_content_from(response)
    return answer unless answer.nil? || answer.empty?

    warn_failure(response)
  end

  def message_content_from(response)
    return nil unless response&.body

    parsed = Oj.load(response.body)
    return nil unless parsed.is_a?(Hash)

    message = parsed.dig("choices", 0, "message")
    return nil unless message.is_a?(Hash)

    content = message["content"]
    content.nil? || content.empty? ? message["reasoning_content"] : content
  end

  def warn_failure(response)
    status = response&.status || "Unknown"
    raw = response&.body.to_s
    warn "⚠️  OpenRouter fallback failed (#{status})"
    ErrorResponseBody.warn_if_present("", raw)
    nil
  end

  def debug_request(body, source_model)
    warn "--- OpenRouter fallback request (source=#{source_model || "unknown"}) ---"
    warn Oj.dump(body, mode: :compat, indent: 2)
    warn "--- end OpenRouter request ---"
  end

  def debug_response(answer)
    warn "\n--- OpenRouter fallback response ---"
    warn answer.to_s.empty? ? "(empty response)" : answer
    warn "--- end OpenRouter response ---\n"
  end

  def handle_json_response(answer, messages, max_completion_tokens)
    return answer if OpenrouterJson.valid?(answer)

    extracted = OpenrouterJson.extract_from_text(answer)
    if extracted
      warn "⚠️  OpenRouter returned non-JSON for JSON request, extracted JSON from text" if @debug
      return extracted
    end

    retry_without_json_constraint(messages, max_completion_tokens)
  end

  def retry_without_json_constraint(messages, max_completion_tokens)
    warn "⚠️  OpenRouter returned non-JSON for JSON request, retrying without JSON constraint"
    body_no_json = build_request_body(messages, json: false, max_completion_tokens: max_completion_tokens)
    response = post_with_retry(body_no_json)
    return warn_failure(response) unless response.status == 200

    answer = extract_answer(response)
    OpenrouterJson.extract_from_text(answer) || answer if answer
  end
end
