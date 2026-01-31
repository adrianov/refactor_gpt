# frozen_string_literal: true

require 'oj'
require 'json'

# Parses stream-json lines from agent output into type, text, stream_id, command, and tool_info.
# Extracted from AgentExecutor to reduce class length and ABC.
class JsonStreamParser
  def parse(line)
    return [nil] * 5 if line.nil? || line.to_s.strip.empty?

    json_obj = Oj.load(line.to_s.strip)
    type = json_obj['type']
    return [nil] * 5 if parse_skip_type?(json_obj, type)

    parse_build_result(json_obj, type)
  rescue Oj::ParseError, JSON::ParserError
    [nil] * 5
  end

  def parse_build_result(json_obj, type)
    stream_id = json_obj['request_id'] || json_obj['stream_id'] || type
    text = extract_text_from_json(json_obj)&.to_s
    cmd = extract_command_from_json(json_obj)
    tool = extract_tool_call_info(json_obj) if %w[tool_call tool_result].include?(type)
    [type, text, stream_id, cmd, tool]
  end

  private

  def parse_skip_type?(json_obj, type)
    %w[user system].include?(type) ||
      (type == 'thinking' && (json_obj['text'].nil? || json_obj['text'].empty?))
  end

  def extract_text_from_json(json_obj)
    case json_obj['type']
    when 'assistant' then assistant_text(json_obj)
    when 'result' then json_obj['result']
    when 'thinking' then thinking_text(json_obj)
    when 'step', 'tool_call', 'tool_result' then step_like_text(json_obj)
    else json_obj['text'] || json_obj['content'] || json_obj['result'] || json_obj['message']
    end
  end

  def assistant_text(json_obj)
    content = json_obj.dig('message', 'content')
    return content if content.is_a?(String) && !content.to_s.strip.empty?

    text = assistant_text_from_array(content)
    return text if text && !text.to_s.strip.empty?

    json_obj.dig('message', 'text') || json_obj['text']
  end

  def assistant_text_from_array(content)
    return nil unless content.is_a?(Array)

    text_content = content.find { |c| c['type'] == 'text' }
    text_content ? text_content['text'] : nil
  end

  def thinking_text(json_obj)
    text = json_obj['text']
    (text.nil? || text.to_s.strip.empty?) ? nil : text
  end

  def step_like_text(json_obj)
    json_obj['step'] || json_obj['text'] || json_obj['content'] || json_obj['result']
  end

  def extract_command_from_json(json_obj)
    return json_obj['command'] if json_obj['command']
    return nil unless %w[tool_call tool_result].include?(json_obj['type'])

    tool_call = json_obj['tool_call'] || json_obj
    cmd = command_from_tool_call(tool_call)
    return cmd if cmd

    extract_command_from_text(extract_text_from_json(json_obj))
  end

  def command_from_tool_call(tool_call)
    func_name = tool_call.dig('function', 'name')
    func_args = tool_call.dig('function', 'arguments')
    cmd = command_from_func_args(func_name, func_args)
    return cmd if cmd

    input = tool_call['input']
    return input if input.is_a?(String) && input.match?(/^[a-zA-Z0-9_\-\.\/\s]+$/) && input.length < 200
    tool_call['command']
  end

  def command_from_func_args(func_name, func_args)
    return nil unless func_name&.match?(/^(run|execute|command)/i) && func_args

    args = parse_func_args(func_args)
    return args['command'] || args['cmd'] || args['input'] if args.is_a?(Hash)
    return func_args if func_args.is_a?(String) && func_args.match?(/^[a-zA-Z0-9_\-\.\/\s]+$/)

    nil
  rescue Oj::ParseError, JSON::ParserError
    func_args.is_a?(String) && func_args.length < 200 ? func_args : nil
  end

  def parse_func_args(func_args)
    func_args.is_a?(String) ? Oj.load(func_args) : func_args
  end

  def extract_command_from_text(text)
    return nil unless text.is_a?(String)

    patterns = [
      /Running:\s*([^\n]+)/i,
      /Executing:\s*([^\n]+)/i,
      /Command:\s*([^\n]+)/i,
      /`([^`]+)`/
    ]
    patterns.each do |pattern|
      match = text.match(pattern)
      next unless match && match[1]
      cmd = match[1].to_s.strip
      return cmd if looks_like_command?(cmd)
    end
    nil
  end

  def looks_like_command?(cmd)
    s = cmd.to_s
    return false unless command_length_ok?(s)
    return false unless s.match?(/^[a-zA-Z0-9_\-\.\/\s\:\;\,\|\&\<\>\(\)\"\']+$/)
    return false if s.strip !~ /\s/ && !s.include?('/') && !s.match?(/^\-+\w/)

    command_looks_executable?(s)
  end

  def command_length_ok?(s)
    s.length >= 4 && s.length <= 500
  end

  def command_looks_executable?(s)
    s.match?(/\b(rspec|rake|make|npm|yarn|bundle|ruby|python|node|go| cargo|test|spec|build|run)\b/i) ||
      s.match?(/[\/\-]/) ||
      s.match?(/^[a-z]+\s+[a-z]/i)
  end

  def extract_tool_call_info(json_obj)
    return nil unless %w[tool_call tool_result].include?(json_obj['type'])

    tool_call = json_obj['tool_call'] || json_obj
    func_name = extract_tool_name(tool_call, json_obj)
    return nil unless func_name

    {
      name: func_name,
      arguments: parse_tool_args(extract_tool_args(tool_call, json_obj)),
      subtype: json_obj['subtype'],
      result: json_obj['result'] || json_obj['content']
    }
  end

  def extract_tool_name(tool_call, json_obj)
    func_name = tool_call.dig('function', 'name') || json_obj['function_name'] || json_obj['name']
    return func_name if func_name

    tool_call.keys.each do |key|
      next unless key.end_with?('ToolCall') || key.end_with?('Call')
      tool_key = key.sub(/ToolCall$/, '').sub(/Call$/, '')
      return format_tool_name(tool_key)
    end
    nil
  end

  def format_tool_name(name)
    name = name.sub(/^[a-z]/, &:upcase) if name.match?(/^[a-z]/)
    formatted = name.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
    formatted = formatted.sub(/_tool$/, '')
    formatted
  end

  def extract_tool_args(tool_call, json_obj)
    func_args = tool_call.dig('function', 'arguments') || json_obj['arguments'] || json_obj['args']
    return func_args if func_args

    tool_call.each do |key, value|
      next unless key.end_with?('ToolCall') || key.end_with?('Call')
      return value['args'] if value.is_a?(Hash) && value['args']
      return value if value.is_a?(Hash)
    end
    nil
  end

  def parse_tool_args(func_args)
    return func_args unless func_args.is_a?(String)
    Oj.load(func_args)
  rescue Oj::ParseError, JSON::ParserError
    func_args
  end
end
