#!/usr/bin/env ruby
# frozen_string_literal: true

require "colorize"
require_relative "lib/openai_client"
require_relative "lib/agents_file_handler"
require "shellwords"

# Class to interact with OpenAI API
class OpenAi
  include AgentsFileHandler

  def initialize(model: nil, debug: false)
    @client = OpenAiClient.new(model: model, debug: debug,
      progress_title: "Refactoring code".cyan)
  end

  # Method to send prompts to OpenAI and get a response
  def ask(prompts, json: false)
    @client.ask(prompts, json: json)
  end

  # Method to refactor code based on user instructions
  def refactor(file_codes, user_instruction = nil)
    ask(
      [
        {role: "system", content: build_system_instruction},
        {role: "user", content: build_refactor_prompt(file_codes, user_instruction)}
      ]
    )
  end

  private

  def build_system_instruction
    agents_content = load_agents_file
    has_agents = !agents_content.empty?

    parts = [base_system_instruction]
    parts << "Follow Ruby development guidelines from AGENTS.md." if has_agents
    parts << agents_guideline_section(agents_content) if has_agents

    parts.join
  end

  def base_system_instruction
    <<~HEREDOC
      Return refactored files using this format:
      <replace filename="[REPLACE_WITH_ACTUAL_FILE_PATH]">complete file content</replace>

      The <replace> tags and the complete file content between them must be
      output on separate lines. The file content between the opening and
      closing tags can span multiple lines and must include every line of the
      file exactly as it should appear.

      Files provided as context use this format in the prompt and must NOT be
      returned:
      <content filename="path/to/file.rb">complete file content</content>

      Content between <replace> and </replace> tags MUST be the complete file
      content from the first line to the last line. Never abbreviate, cut, or
      use placeholders like "...". Always include all lines of the file.

      Content between <content> and </content> tags in the prompt is provided as
      reference only. Never return files that were marked with <content>. Only
      return files you actually modify.

      Preserve all existing comments unless they describe code you change or
      you implement a TODO. When making bug fixes or applying specific requested
      changes, keep the diff as small as possible (minimal changed lines).
      Never suggest purely stylistic changes (quote style, alternative method
      names). Only make necessary structural improvements.
    HEREDOC
  end

  def agents_guideline_section(agents_content)
    <<~HEREDOC

      AGENTS.md content (development guidelines to follow):
      #{agents_content}

    HEREDOC
  end

  def build_refactor_prompt(file_codes, user_instruction)
    <<~HEREDOC
      #{user_instruction || DEFAULT_USER_INSTRUCTION}

      Files are provided below using <content> tags. You may use some files only as
      context and leave them unchanged. Only return files you actually modify.

      #{file_codes.map { |path, code| "<content filename=\"#{path}\">#{code}</content>" }.join("\n\n")}
    HEREDOC
  end

  DEFAULT_USER_INSTRUCTION = <<~HEREDOC
    You are refactoring the following code. Apply these rules unless the user
    explicitly overrides them:

    1. Correctness & Robustness
       - Identify and fix bugs or obvious mistakes.
       - Improve error handling where it is clearly insufficient or unsafe.
       - Prefer failing fast with clear messages over silent failures.

    2. Readability & Naming
       - Use clear, descriptive names for variables, methods, and classes.
       - Avoid unnecessary abbreviations unless they are domain-standard.

    3. Structure & Size
       - Prefer small, focused methods.
       - Where it improves clarity, extract helper methods instead of enforcing
         an arbitrary line limit.
       - Keep lines reasonably short (aim for <= 100 characters), but do not
         harm readability just to satisfy a strict width.

    4. Simplicity
       - Simplify complex conditionals and branching where possible.
       - Remove dead code and unnecessary indirection.
       - Inline variables that are used only once when it improves clarity.

    5. Style & Consistency
       - Follow idiomatic Ruby style (Ruby community conventions).
       - Keep formatting consistent with the surrounding code.

    6. Comments & Documentation
       - Preserve all existing comments verbatim unless they refer to code you
       significantly change or a TODO you implement.
       - Do not add new comments unless the user explicitly asks for them.

    7. Behavior Preservation
       - Preserve existing business logic and external behavior unless there is
         a clear bug or the user explicitly requests a change.
       - When you must change behavior to fix a bug, keep the change as small
         and local as possible.

    8. TODOs
       - Implement TODOs only if they are fully specified and safe to complete
       without guessing about missing requirements.
       - If a TODO is ambiguous, leave it in place and do not invent behavior.

    9. Default Behavior
       - Do not change code behavior unless the user specifically asks for it
       or a change is required to fix a clear bug.
  HEREDOC
end

# Helper class to parse OpenAI response
class ResponseParser
  def self.parse_files_from_response(response, expected_paths)
    result = parse_text_response(response, expected_paths)
    validate_parsed_files(result, expected_paths)
    apply_single_file_fallback(result, response, expected_paths) || result
  end

  def self.parse_text_response(response, _expected_paths)
    result = {}
    remaining = response.dup

    while remaining
      match = remaining.match(%r{^<replace filename="([^"]+)">(.*?)\n</replace>}m)
      break unless match

      filename = match[1]
      next if placeholder_filename?(filename)

      content = match[2]
      result[filename] = content
      remaining = remaining[(match.end(0))..]
    end

    result
  end

  def self.placeholder_filename?(filename)
    filename == "[REPLACE_WITH_ACTUAL_FILE_PATH]"
  end

  def self.validate_parsed_files(result, expected_paths)
    result.each do |filename, content|
      unless expected_paths.include?(filename)
        warn "Warning: Parsed file '#{filename}' was not in expected files: #{expected_paths.join(", ")}"
      end

      if content.strip.empty?
        warn "Warning: Empty content for file '#{filename}'"
      end
    end
  end

  def self.apply_single_file_fallback(result, response, expected_paths)
    return if !result.empty? || expected_paths.size != 1
    {expected_paths.first => response}
  end
end

# Class to handle file operations and diff display
class FileProcessor
  def initialize(file_codes)
    @file_codes = file_codes
  end

  def process_refactored_files(refactored_files, elapsed_time)
    log_file_counts(refactored_files)
    process_each_file(refactored_files, elapsed_time)
    report_missing_files(refactored_files)
  end

  private

  def log_file_counts(refactored_files)
    return unless @file_codes.size > 1 || refactored_files.size > 1
    warn "Expected files: #{@file_codes.keys.join(", ")}"
    warn "Parsed files: #{refactored_files.keys.join(", ")}"
  end

  def process_each_file(refactored_files, elapsed_time)
    refactored_files.each do |path, content|
      next unless @file_codes.key?(path)

      content = ensure_trailing_newline(content)
      original_code = @file_codes[path]

      display_file_stats(path, content, elapsed_time, original_code)
      next if original_code == content

      handle_file_modification(path, original_code, content)
    end
  end

  def report_missing_files(refactored_files)
    missing_files = @file_codes.keys - refactored_files.keys
    return if missing_files.empty?
    warn "No replacement content for files: #{missing_files.join(", ")}"
  end

  def ensure_trailing_newline(content)
    return content if content.empty? || content[-1] == "\n"
    content + "\n"
  end

  def display_file_stats(path, refactored_code, elapsed_time, original_code)
    puts "\nFile: #{path}"
    puts "Original size: #{original_code.size} characters"
    puts "Refactored size: #{refactored_code.size} characters"
    puts "Elapsed time: #{elapsed_time.round(2)} seconds"
    speed = calculate_speed(refactored_code.size, elapsed_time)
    puts "Speed: #{speed} characters per second"

    if refactored_code.size < original_code.size * 0.5
      warn "Warning: Refactored code is much smaller than original (possible truncation)"
    end
  end

  def calculate_speed(size, elapsed_time)
    return 0 unless elapsed_time.positive?
    (size / elapsed_time).round(2)
  end

  def handle_file_modification(path, original_code, refactored_code)
    is_git_repository = check_git_repository(path)
    create_backup(path, original_code) unless is_git_repository
    write_refactored_file(path, refactored_code)
    display_diff(path, is_git_repository)
  end

  def check_git_repository(path)
    system(
      "git ls-files --error-unmatch " \
      "#{Shellwords.shellescape(path)} > #{File::NULL} 2>&1"
    )
  end

  def create_backup(path, original_code)
    backup_file_path = "#{path}.bak"
    File.binwrite(backup_file_path, original_code)
  rescue SystemCallError => e
    warn "Failed to write backup file #{backup_file_path}: #{e.message}"
    exit 1
  end

  def write_refactored_file(path, refactored_code)
    warn "Writing file: #{path} (#{refactored_code.size} bytes)"
    File.binwrite(path, refactored_code)
  rescue SystemCallError => e
    warn "Failed to write refactored file #{path}: #{e.message}"
    exit 1
  end

  def display_diff(path, is_git_repository)
    if is_git_repository
      system("git diff -w #{Shellwords.shellescape(path)}")
    else
      backup_file_path = "#{path}.bak"
      system(
        "diff -u --color #{Shellwords.shellescape(backup_file_path)} " \
        "#{Shellwords.shellescape(path)}"
      )
    end
  end
end

# Main runner class
class RefactorGptRunner
  def initialize
    @file_paths = []
    @user_instruction_parts = []
  end

  def run(args)
    parse_arguments(args)
    validate_files

    file_codes = read_files
    raw_response, elapsed_time = with_timing do
      OpenAi.new.refactor(file_codes, user_instruction).to_s
    end

    refactored_files = ResponseParser.parse_files_from_response(raw_response, @file_paths)
    FileProcessor.new(file_codes).process_refactored_files(refactored_files, elapsed_time)
  end

  private

  def with_timing
    start_time = Time.now
    result = yield
    elapsed_time = Time.now - start_time
    [result, elapsed_time]
  end

  def parse_arguments(args)
    args.each do |arg|
      if File.exist?(arg)
        @file_paths << arg
      else
        @user_instruction_parts << arg
      end
    end
  end

  def validate_files
    return unless @file_paths.empty?

    puts "No valid files provided."
    exit 1
  end

  def user_instruction
    return if @user_instruction_parts.empty?
    @user_instruction_parts.join(" ")
  end

  def read_files
    @file_paths.each_with_object({}) do |file_path, file_codes|
      begin
        file_codes[file_path] = File.binread(file_path).force_encoding("UTF-8")
      rescue SystemCallError => e
        warn "Failed to read file #{file_path}: #{e.message}"
        exit 1
      end
    end
  end
end

# Script entry point
if ARGV.empty?
  puts(
    "Usage: #{File.basename($PROGRAM_NAME)} <file1> [file2 ...] " \
    '["Instructions what to do."]'
  )
  exit 1
end

RefactorGptRunner.new.run(ARGV)
