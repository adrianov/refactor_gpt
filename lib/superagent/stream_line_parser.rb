# frozen_string_literal: true

# Parses one raw stream-json line into a structured hash (type, text, result, stream_id,
# command, tool, think_close_only, trailing_think_close). For type=result, content is in :result.
class StreamLineParser
  THINK_CLOSE_ONLY = /\A\s*`*\s*<\/think>\s*`*\s*\z/i
  THINK_CLOSE_TAIL = /\s*`*\s*<\/think>\s*`*\s*\z/i

  def initialize(json_parser: nil)
    @json_parser = json_parser || JsonStreamParser.new
  end

  def parse_stream_line(line)
    raw = line.to_s.strip
    type, text, stream_id, command, tool = @json_parser.parse(raw)
    think_close_only = (type.nil? || type.to_s == 'assistant' || type.to_s == 'thinking') &&
                       think_close_only?(text)
    trailing_think_close = trailing_think_close?(text)
    result = (type.to_s == 'result' ? text : nil)
    {
      type: type, text: text, result: result, stream_id: stream_id, command: command, tool: tool,
      think_close_only: think_close_only, trailing_think_close: trailing_think_close
    }
  end

  private

  def think_close_only?(text)
    return false if text.nil? || text.to_s.strip.empty?

    text.to_s.strip.gsub(/\p{C}+/, '').match?(THINK_CLOSE_ONLY)
  end

  def trailing_think_close?(text)
    return false if text.nil? || text.to_s.empty?

    text.to_s.gsub(/\p{C}+/, '').match?(THINK_CLOSE_TAIL)
  end
end
