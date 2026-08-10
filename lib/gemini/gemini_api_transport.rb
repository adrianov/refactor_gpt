# frozen_string_literal: true

require 'oj'

# Wire protocol for Gemini streamGenerateContent: build payload, POST or SSE, assemble text.
class GeminiApiTransport
  def initialize(api_base_url:, api_key:, model:, proxy_url:, request_timeout:, debug:, content_stream:)
    @api_base_url = api_base_url
    @api_key = api_key
    @model = model
    @proxy_url = proxy_url
    @request_timeout = request_timeout
    @debug = debug
    @content_stream = content_stream
  end

  def last_payload_bytes
    @content_stream.last_payload_bytes
  end

  def endpoint
    "#{@api_base_url}/models/#{@model}:streamGenerateContent?alt=sse"
  end

  def build_body(messages, json: false)
    @content_stream.build_body(messages, json: json)
  end

  # Posts once (buffered or SSE). Caller must check HTTP status before reading the body.
  def submit(messages, json: false, stream: false)
    body = build_body(messages, json: json)
    log_request(body)
    post(body, stream: stream)
  end

  def each_text_chunk(response, &block)
    @content_stream.each_text_chunk(response, &block)
  end

  def parse_answer(response)
    @content_stream.extract_answer(@content_stream.assemble(response))
  end

  def post(body, stream: false)
    params = {
      headers: request_headers,
      body: Oj.dump(body, mode: :compat)
    }
    params[:stream] = true if stream
    PrimaryApiHttp.build(timeout: @request_timeout, proxy_url: @proxy_url, stream: stream)
      .post(endpoint, **params)
  end

  def request_headers
    {
      'Content-Type' => 'application/json',
      'x-goog-api-key' => @api_key
    }
  end

  def log_request(body)
    return unless @debug

    warn "--- Gemini request ---\n#{Oj.dump(body, mode: :compat, indent: 2)}\n--- end request ---"
  end

  def log_response(answer)
    return unless @debug

    warn "\n--- Gemini response ---\n#{format_debug_body(answer)}\n--- end response ---\n"
  end

  def format_debug_body(answer)
    return '(empty response)' if answer.nil?
    return answer if answer.is_a?(String)

    Oj.dump(answer, mode: :compat, indent: 2)
  end

  # Transient Gemini/stream failures that should retry or fall back (stall, cancel, quota).
  def self.transient_failure?(message)
    text = message.to_s
    text.include?('resource_exhausted') ||
      text.match?(/connection\s+stalled/i) ||
      text.include?('CANCEL') ||
      text.include?('canceled') ||
      text.include?('stream closed') ||
      text.include?('0x8')
  end

  def transient_failure?(message)
    self.class.transient_failure?(message)
  end
end
