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

    [type, text_for(obj, type), stream_id_for(obj, type), nil, tool_for_if(obj, type)]
  rescue Oj::ParseError, JSON::ParserError
    [nil] * 5
  end

  private

  def skip_type?(obj, type)
    return true if %w[user system].include?(type)
    return true if type == 'thinking' && (obj['text'].nil? || obj['text'].to_s.strip.empty?)

    false
  end

  def text_for(obj, type)
    case type
    when 'thinking' then obj['text']&.to_s
    when 'assistant' then assistant_text(obj)
    when 'result' then obj['result']&.to_s
    else nil
    end
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

  def stream_id_for(obj, type)
    obj['request_id'] || obj['stream_id'] || type
  end

  def tool_for_if(obj, type)
    type == 'tool_call' ? tool_for(obj) : nil
  end

  def tool_for(obj)
    payload = obj['tool_call']
    return nil unless payload.is_a?(Hash)

    key = payload.keys.find { |k| k.to_s.end_with?('ToolCall') }
    return nil unless key

    value = payload[key]
    build_tool_hash(tool_name_from_key(key), value, obj['subtype'])
  end

  def build_tool_hash(name, value, subtype)
    args = value.is_a?(Hash) ? value['args'] : nil
    result = value.is_a?(Hash) ? value['result'] : nil
    {
      name: name,
      arguments: args.is_a?(String) ? parse_json_safe(args) : args,
      subtype: subtype,
      result: result
    }
  end

  def tool_name_from_key(key)
    name = key.to_s.sub(/ToolCall\z/, '')
    name.gsub(/([a-z])([A-Z])/, '\1_\2').downcase.sub(/_tool\z/, '')
  end

  def parse_json_safe(str)
    Oj.load(str)
  rescue Oj::ParseError, JSON::ParserError
    str
  end
end
