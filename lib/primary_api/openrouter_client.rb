# frozen_string_literal: true

require "httpx"
require "oj"

# OpenRouter fallback client for primary provider outages and rate limits.
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
    answer = handle_json_response(answer, json, messages, max_completion_tokens) if json && answer
    
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
      ssl: PrimaryApiSsl.httpx_options,
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

  def valid_json?(text)
    return false if text.nil? || text.to_s.strip.empty?
    
    Oj.load(text.to_s)
    true
  rescue Oj::ParseError
    false
  end

  def handle_json_response(answer, _json_requested, messages, max_completion_tokens)
    return answer if valid_json?(answer)

    # Try to extract JSON from the text first
    extracted = extract_json_from_text(answer)
    if extracted
      warn "⚠️  OpenRouter returned non-JSON for JSON request, extracted JSON from text" if @debug
      return extracted
    end

    # Retry without JSON constraint
    retry_without_json_constraint(messages, max_completion_tokens)
  end

  def retry_without_json_constraint(messages, max_completion_tokens)
    warn "⚠️  OpenRouter returned non-JSON for JSON request, retrying without JSON constraint"
    body_no_json = build_request_body(messages, json: false, max_completion_tokens: max_completion_tokens)
    response = post_with_retry(body_no_json)
    return warn_failure(response) unless response.status == 200
    
    answer = extract_answer(response)
    extract_json_from_text(answer) || answer if answer
  end

  def extract_json_from_text(text)
    return nil if text.nil? || text.to_s.strip.empty?
    
    content = text.to_s
    
    # Try markdown code blocks first
    extracted = try_extract_from_markdown(content)
    return extracted if extracted
    
    # Try to find balanced JSON braces
    try_extract_balanced_json(content)
  end

  def try_extract_from_markdown(content)
    # Match markdown code blocks and extract everything between the braces
    json_match = content.match(/```(?:json)?\s*(\{.*\})\s*```/m)
    return nil unless json_match
    
    # Extract the full content and find balanced JSON within it
    code_block_content = json_match[1].strip
    extract_balanced_json_from_content(code_block_content)
  end

  def try_extract_balanced_json(content)
    brace_start = content.index('{')
    return nil unless brace_start
    
    brace_end = find_matching_brace(content, brace_start)
    return nil unless brace_end
    
    candidate = content[brace_start..brace_end]
    candidate if valid_json?(candidate)
  end

  def extract_balanced_json_from_content(content)
    # If the content starts with {, try to find the matching closing brace
    return content if content.start_with?('{') && content.end_with?('}') && valid_json?(content)
    
    # Otherwise, find the first { and its matching }
    brace_start = content.index('{')
    return nil unless brace_start
    
    brace_end = find_matching_brace(content, brace_start)
    return nil unless brace_end
    
    candidate = content[brace_start..brace_end]
    candidate if valid_json?(candidate)
  end

  def find_matching_brace(content, start_pos)
    brace_count = 0
    
    content[start_pos..-1].each_char.with_index(start_pos) do |char, idx|
      case char
      when '{'
        brace_count += 1
      when '}'
        brace_count -= 1
        return idx if brace_count == 0
      end
    end
    
    nil
  end
end
