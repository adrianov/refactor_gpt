# frozen_string_literal: true

require 'oj'
require 'json'

# Parses NDJSON agent stream: one JSON object per line (LINE_SEP). Returns type, text, stream_id, command, tool.
# Log format: type (system|user|thinking|assistant|tool_call|result), message.content, tool_call.*ToolCall.
class JsonStreamParser
  LINE_SEP = "\n"

  def parse(line)
    return [nil] * 5 if line.nil? || line.to_s.strip.empty?

    obj = Oj.load(line.to_s.strip)
    type = obj['type']
    return [nil] * 5 if skip_type?(obj, type)

    build_parse_result(obj, type)
  rescue Oj::ParseError, JSON::ParserError
    [nil] * 5
  end

  private

  def build_parse_result(obj, type)
    stream_id = obj['request_id'] || obj['stream_id'] || type
    tool = (type == 'tool_call' ? tool_for(obj) : nil)
    [type, text_for(obj, type), stream_id, nil, tool]
  end

  def skip_type?(_obj, type)
    return true if %w[user system].include?(type)
    return true if type == 'thinking'

    false
  end

  def text_for(obj, type)
    case type
    when 'thinking' then obj['text']&.to_s
    when 'assistant' then assistant_text(obj)
    when 'result' then result_content(obj)
    else nil
    end
  end

  # type=result: value may be string or { "result" => "..." } or { "content" => "..." }; collapses 3+ newlines to two.
  def result_content(obj)
    r = obj['result']
    return nil if r.nil?
    raw = (r.is_a?(Hash) ? (r['result'] || r['content']).to_s : r.to_s)
    raw.gsub(/\n{3,}/, "\n\n")
  end

  def assistant_text(obj)
    content = obj.dig('message', 'content')
    return content if content.is_a?(String) && !content.to_s.strip.empty?

    text = text_from_content_array(content)
    return text if text && !text.to_s.strip.empty?

    obj.dig('message', 'text') || obj['text']
  end

  def text_from_content_array(content)
    return nil unless content.is_a?(Array)

    block = content.find { |c| c['type'] == 'text' }
    block ? block['text'] : nil
  end

  def tool_for(obj)
    payload = obj['tool_call']
    return nil unless payload.is_a?(Hash)

    key = payload.keys.find { |k| k.to_s.end_with?('ToolCall') }
    return nil unless key

    value = payload[key]
    name = key.to_s.sub(/ToolCall\z/, '').gsub(/([a-z])([A-Z])/, '\1_\2').downcase.sub(/_tool\z/, '')
    build_tool_hash(name, value, obj['subtype'])
  end

  def build_tool_hash(name, value, subtype)
    args = value.is_a?(Hash) ? value['args'] : nil
    result = value.is_a?(Hash) ? value['result'] : nil
    parsed_args = args.is_a?(String) ? (Oj.load(args) rescue args) : args
    { name: name, arguments: parsed_args, subtype: subtype, result: result }
  end
end
