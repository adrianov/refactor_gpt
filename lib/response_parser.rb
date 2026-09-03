# frozen_string_literal: true

require 'oj'

# Helper class to parse OpenAI response
class ResponseParser
  FILE_REPLACE_PATTERN = %r{
    <full_file_contents_to_replace\s+filename="([^"]+)">\r?\n?(.*?)\r?\n?</full_file_contents_to_replace>
  }mx

  def self.parse_files_from_response(response, expected_paths, exit_on_error: true)
    result = parse_text_response(response, expected_paths)
    validate_parsed_files(result, expected_paths)

    if result.empty? && exit_on_error
      warn "Error: No files were parsed from response. Response must use <full_file_contents_to_replace> tags."
      exit 1
    end

    result
  end

  def self.parse_text_response(response, _expected_paths)
    result = {}
    remaining = response.dup

    while remaining
      match = remaining.match(FILE_REPLACE_PATTERN)
      break unless match

      filename = match[1]
      content = match[2]
      result[filename] = content
      remaining = remaining[(match.end(0))..]
    end

    result
  end

  def self.validate_parsed_files(result, expected_paths)
    result.each do |filename, content|
      unless expected_paths.include?(filename)
        warn "Warning: Parsed file '#{filename}' was not in expected files: #{expected_paths.join(", ")}"
      end

      if content.nil? || content.to_s.strip.empty?
        warn "Warning: Empty content for file '#{filename}'"
      end
    end
  end

  def self.extract_json(text)
    return nil if text.nil? || text.to_s.strip.empty?

    # First, try to find a JSON block in markdown
    json_match = text.match(/```(?:json)?\s*(\{.*?\})\s*```/m)
    return Oj.load(json_match[1]) if json_match

    # Fallback 1: Try to load the whole text (it might be pure JSON)
    begin
      return Oj.load(text)
    rescue Oj::ParseError
      # ignore and try fallback 2
    end

    # Fallback 2: Find the first { and the last }
    braces_match = text.match(/(\{.*\})/m)
    return Oj.load(braces_match[1]) if braces_match

    raise Oj::ParseError, "Could not find valid JSON in response: #{text[0..100]}..."
  end
end
