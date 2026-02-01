# frozen_string_literal: true

# Parses one raw stream-json line into a structured hash (type, text, stream_id, command,
# tool, think_close_only, trailing_think_close).
class StreamLineParser
  def initialize(json_parser: nil)
    @json_parser = json_parser || JsonStreamParser.new
  end

  def parse_stream_line(line)
    raw = line.to_s.strip
    type, text, stream_id, command, tool = @json_parser.parse(raw)
    think_only = (type.nil? || type.to_s == 'assistant' || type.to_s == 'thinking') &&
                 StreamFilter.think_close_only?(text)
    trailing = StreamFilter.trailing_think_close?(text)
    {
      type: type, text: text, stream_id: stream_id, command: command, tool: tool,
      think_close_only: think_only, trailing_think_close: trailing
    }
  end
end
