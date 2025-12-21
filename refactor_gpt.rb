#!/usr/bin/env ruby
# frozen_string_literal: true

require "colorize"
require_relative "lib/openai_client"
require_relative "lib/agents_file_handler"
require "shellwords"
require "json"

# Class to interact with OpenAI API
class OpenAi
  include AgentsFileHandler

  def initialize(model: nil, debug: false)
    @client = OpenAiClient.new(model: model, debug: debug,
      progress_title: "Refactoring code".cyan)
  end

  # Method to send prompts to OpenAI and get a response
  def ask(prompts)
    @client.ask(prompts)
  end

  # Method to refactor code based on user instructions
  def refactor(file_codes, user_instruction = nil)
    system_instruction = build_system_instruction
    prompt = build_refactor_prompt(file_codes, user_instruction)
    
    ask(
      [
        {role: "system", content: system_instruction},
        {role: "user", content: prompt}
      ]
    )
  end

  private

  def build_system_instruction
    agents_content = load_agents_file
    has_agents = !agents_content.empty?
    
    parts = [base_system_instruction]
    parts << "Follow Ruby development guidelines from AGENTS.md." if has_agents
    parts << json_format_instruction
    parts << agents_guideline_section(agents_content) if has_agents
    
    parts.join
  end

  def base_system_instruction
    <<~HEREDOC
      Return a JSON response with the refactored code modules. Strictly preserve existing
      comments unless implemented TODOs or changed code fragment business logic,
      if not asked otherwise. When making bug fixes or applying specific requested
      changes, keep the diff as small as reasonably possible in terms of changed
      lines.
      Do not suggest changes that are purely stylistic choices - e.g. type of
      quotes, alternative method names. Only suggest real structural changes.
    HEREDOC
  end

  def json_format_instruction
    <<~HEREDOC

      When multiple files are provided, respond with JSON in the following format:
      {
        "files": [
          {
            "path": "<relative-or-given-path-1>",
            "content": "<full file content 1>"
          },
          {
            "path": "<relative-or-given-path-2>",
            "content": "<full file content 2>"
          }
        ]
      }

      Some files may be used only as context and left unchanged - include all
      provided files in the response with their original or modified content.
    HEREDOC
  end

  def agents_guideline_section(agents_content)
    <<~HEREDOC

        AGENTS.md content (development guidelines to follow):
        #{agents_content}

      HEREDOC
  end

  def build_refactor_prompt(file_codes, user_instruction)
    files_block = file_codes.map { |path, code| "File: #{path}\n#{code}" }.join("\n\n")
    
    <<~HEREDOC
      #{user_instruction || default_user_instruction}

      You may use some files only as context and leave them unchanged.

      #{files_block}
    HEREDOC
  end

  def default_user_instruction
    <<~HEREDOC
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
end

# Helper class to parse OpenAI response
class ResponseParser
  def self.parse_files_from_response(response, expected_paths)
    result = try_parse_json(response) || parse_text_response(response, expected_paths)
    apply_single_file_fallback(result, response, expected_paths) || result
  end

  def self.try_parse_json(response)
    json_response = JSON.parse(response)
    return unless json_response["files"]&.is_a?(Array)
    
    json_response["files"].each_with_object({}) do |file, hash|
      path = file["path"]
      content = file["content"]
      hash[path] = content if path && content
    end
  rescue JSON::ParserError
    nil
  end

  def self.parse_text_response(response, expected_paths)
    result = {}
    current_path = nil
    buffer = []

    response.each_line do |line|
      if line.start_with?("=== FILE: ")
        finalize_current_file(result, current_path, buffer)
        current_path = extract_file_path(line)
        buffer = []
      elsif current_path
        buffer << line
      end
    end

    finalize_current_file(result, current_path, buffer)
    result
  end

  def self.finalize_current_file(result, current_path, buffer)
    return unless current_path

    result[current_path] = buffer.join
  end

  def self.extract_file_path(line)
    line.sub("=== FILE: ", "").strip
  end

  def self.apply_single_file_fallback(result, response, expected_paths)
    return if !result.empty? || expected_paths.size != 1

    { expected_paths.first => response }
  end
end

# Class to handle file operations and diff display
class FileProcessor
  def initialize(file_codes)
    @file_codes = file_codes
  end

  def process_refactored_files(refactored_files, elapsed_time)
    refactored_files.each do |path, content|
      next unless @file_codes.key?(path)

      content = ensure_trailing_newline(content)
      original_code = @file_codes[path]

      display_file_stats(path, content, elapsed_time)
      next if original_code == content

      handle_file_modification(path, original_code, content)
    end
  end

  private

  def ensure_trailing_newline(content)
    return content if content.empty? || content[-1] == "\n"
    content + "\n"
  end

  def display_file_stats(path, refactored_code, elapsed_time)
    puts "\nFile: #{path}"
    puts "Code size: #{refactored_code.size} characters"
    puts "Elapsed time: #{elapsed_time.round(2)} seconds"
    speed = elapsed_time.positive? ? (refactored_code.size / elapsed_time).round(2) : 0
    puts "Speed: #{speed} characters per second"
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
        code = File.binread(file_path).force_encoding("UTF-8")
      rescue SystemCallError => e
        warn "Failed to read file #{file_path}: #{e.message}"
        exit 1
      end
      file_codes[file_path] = code
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
