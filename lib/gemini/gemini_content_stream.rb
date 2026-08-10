# frozen_string_literal: true

require "oj"

# Gemini streamGenerateContent: request body shape, SSE chunk parse, assembled answer.
class GeminiContentStream
  attr_reader :last_payload_bytes

  def initialize(max_completion_tokens: nil)
    @max_completion_tokens = max_completion_tokens
    @last_payload_bytes = nil
  end

  def build_body(messages, json: false)
    system_text, contents = split_system_and_contents(messages)
    body = {contents: contents}
    body[:systemInstruction] = {parts: [{text: system_text}]} if system_text
    config = {generationConfig: {temperature: 0.7}}
    config[:generationConfig][:maxOutputTokens] = @max_completion_tokens if @max_completion_tokens
    config[:generationConfig][:responseMimeType] = "application/json" if json

    merged = body.merge(config)
    @last_payload_bytes = Oj.dump(merged, mode: :compat).bytesize
    merged
  end

  def each_text_chunk(response)
    return yield_sse_lines(response) { |text| yield text } if response.respond_to?(:each_line)

    yield_buffered_sse(response) { |text| yield text }
  end

  def assemble(response)
    return response unless response.status == 200

    body = response.body.to_s
    chunks = sse_chunks(body)
    chunks = json_array_chunks(body) if chunks.empty?
    combine_chunks(chunks, response)
  end

  def extract_answer(response)
    return nil unless response&.body

    parsed = Oj.load(response.body)
    return nil unless parsed.is_a?(Hash)

    content = parsed.dig("candidates", 0, "content", "parts", 0, "text")
    return content unless content.nil? || content.empty?

    warn "No answer returned from Gemini API. Full response body:"
    warn response.body
    exit 1
  end

  # Assembled non-streaming HTTP response after merging SSE chunks.
  class Response
    attr_reader :status, :body

    def initialize(status, body)
      @status = status
      @body = body
    end
  end

  private

  def split_system_and_contents(messages)
    system_parts = []
    contents = []
    messages.each do |msg|
      role = msg[:role].to_s
      text = msg[:content]
      if role == "system"
        system_parts << text unless text.to_s.empty?
      else
        contents << {role: gemini_content_role(role), parts: [{text: text}]}
      end
    end
    system_text = system_parts.join("\n\n")
    [system_text.empty? ? nil : system_text, contents]
  end

  def gemini_content_role(role)
    (role == "assistant") ? "model" : "user"
  end

  def yield_sse_lines(response)
    response.each_line { |line| emit_text_from_line(line) { |text| yield text } }
  end

  def yield_buffered_sse(response)
    buffer = +""
    each_body_piece(response) do |piece|
      buffer << piece
      flush_sse_lines(buffer) { |text| yield text }
    end
    emit_text_from_line(buffer) { |text| yield text } unless buffer.strip.empty?
  end

  def flush_sse_lines(buffer)
    while (line_end = buffer.index("\n"))
      emit_text_from_line(buffer.slice!(0, line_end + 1)) { |text| yield text }
    end
  end

  def each_body_piece(response)
    body = response.respond_to?(:body) ? response.body : response
    if body.respond_to?(:each) && !body.is_a?(String)
      body.each { |piece| yield piece.to_s }
    else
      yield body.to_s
    end
  end

  def emit_text_from_line(line)
    text = chunk_text(parse_line_json(line))
    yield text if text
  end

  def sse_chunks(body)
    body.each_line.filter_map { |line| parse_line_json(line) }
  end

  def json_array_chunks(body)
    parsed = Oj.load(body)
    return parsed.select { |c| c.is_a?(Hash) } if parsed.is_a?(Array)
    return [parsed] if parsed.is_a?(Hash)

    []
  rescue Oj::ParseError
    []
  end

  def parse_line_json(line)
    line = line.to_s.strip
    return nil if line.empty?

    json_str = line.start_with?("data: ") ? line.sub(/^data: /, "").strip : line
    return nil if json_str.empty? || ["[{", "]", ","].include?(json_str)

    parsed = Oj.load(json_str)
    parsed.is_a?(Hash) ? parsed : nil
  rescue Oj::ParseError
    nil
  end

  def chunk_text(chunk)
    return nil unless chunk.is_a?(Hash)

    chunk.dig("candidates", 0, "content", "parts", 0, "text")&.to_s
  end

  def combine_chunks(chunks, original_response)
    hashes = chunks.select { |c| c.is_a?(Hash) }
    return original_response if hashes.empty?

    last_chunk = hashes.last
    combined_text = hashes.map { |c| chunk_text(c) }.compact.join
    usage = last_chunk["usageMetadata"]
    body = {
      "candidates" => [{
        "content" => {"role" => "model", "parts" => [{"text" => combined_text}]},
        "finishReason" => last_chunk.dig("candidates", 0, "finishReason")
      }],
      "usageMetadata" => usage.is_a?(Hash) ? usage : nil
    }
    Response.new(200, Oj.dump(body, mode: :compat))
  end
end
