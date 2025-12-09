#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/openai_client'
require_relative 'lib/agents_file_handler'
require 'shellwords'

# Class to interact with OpenAI API
class OpenAi
  include AgentsFileHandler

  DEFAULT_MODEL = 'gpt-5.1'

  def initialize(model: DEFAULT_MODEL, debug: false)
    @client = OpenAiClient.new(model: model, debug: debug, progress_title: 'Refactoring code'.cyan)
  end

  # Method to send prompts to OpenAI and get a response
  def ask(prompts)
    @client.ask(prompts)
  end

  # Method to refactor code based on user instructions
  def refactor(file_codes, user_instruction = nil)
    agents_content = load_agents_file
    has_agents = !agents_content.empty?

    system_instruction_parts = []

    system_instruction_parts << <<~HEREDOC
      Return the complete refactored code module only. Strictly preserve existing
      comments unless implemented TODOs or changed code fragment business logic,
      if not asked otherwise. When making bug fixes or applying specific requested
      changes, keep the diff as small as reasonably possible in terms of changed
      lines.
    HEREDOC

    system_instruction_parts << 'Follow Ruby development guidelines from AGENTS.md.' if has_agents

    system_instruction_parts << <<~HEREDOC

      When multiple files are provided, respond with the full content for each
      file in the following structure, in order:

      === FILE: <relative-or-given-path-1>
      <full file content 1>
      === FILE: <relative-or-given-path-2>
      <full file content 2>
      ...

    HEREDOC

    if has_agents
      system_instruction_parts << <<~HEREDOC

        AGENTS.md content (development guidelines to follow):
        #{agents_content}

      HEREDOC
    end

    system_instruction = system_instruction_parts.join
    default_user_instruction = <<~HEREDOC
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

    files_block = file_codes.map do |path, code|
      "=== FILE: #{path}\n```\n#{code}\n```"
    end.join("\n\n")

    prompt = <<~HEREDOC
      #{user_instruction || default_user_instruction}

      You may use some files only as context and leave them unchanged.

      #{files_block}
    HEREDOC

    ask(
      [
        { role: 'system', content: system_instruction },
        { role: 'user', content: prompt }
      ]
    )
  end
end

if ARGV.empty?
  puts(
    "Usage: #{File.basename($PROGRAM_NAME)} <file1> [file2 ...] " \
    '["Instructions what to do."]'
  )
  exit 1
end

file_paths = []
user_instruction_parts = []

ARGV.each do |arg|
  if File.exist?(arg)
    file_paths << arg
  else
    user_instruction_parts << arg
  end
end

if file_paths.empty?
  puts 'No valid files provided.'
  exit 1
end

user_instruction = user_instruction_parts.join(' ') unless user_instruction_parts.empty?

file_codes = {}
total_size = 0

file_paths.each do |file_path|
  begin
    code = File.binread(file_path).force_encoding('UTF-8')
  rescue SystemCallError => e
    warn "Failed to read file #{file_path}: #{e.message}"
    exit 1
  end
  file_codes[file_path] = code
  total_size += code.size
end

start_time = Time.now

raw_response = OpenAi.new.refactor(file_codes, user_instruction).to_s

end_time = Time.now

def parse_files_from_response(response, expected_paths)
  result = {}
  current_path = nil
  buffer = []

  response.each_line do |line|
    if line.start_with?('=== FILE: ')
      if current_path
        result[current_path] = buffer.join
        buffer = []
      end
      current_path = line.sub('=== FILE: ', '').strip
    elsif current_path
      buffer << line
    end
  end

  result[current_path] = buffer.join if current_path

  # Fallback: if structure not respected, treat whole response as single file
  result[expected_paths.first] = response if result.empty? && expected_paths.size == 1

  result
end

def strip_edge_backticks(content)
  lines = content.lines
  return content if lines.empty?

  first = lines.first
  last = lines.last

  first = nil if first.strip == '```' || first.strip.start_with?('```')
  last = nil if last.strip == '```' || last.strip.start_with?('```')

  stripped_lines = []
  stripped_lines << first if first
  stripped_lines.concat(lines[1..-2]) if lines.size > 2
  stripped_lines << last if last && lines.size > 1

  stripped_lines.join.sub(/\A[\r\n]+/, '').sub(/[\r\n]+\z/, '')
end

refactored_files = parse_files_from_response(raw_response, file_paths)

refactored_files.each do |path, content|
  next unless file_codes.key?(path)

  content = strip_edge_backticks(content)
  content += "\n" if !content.empty? && content[-1] != "\n"

  original_code = file_codes[path]
  refactored_code = content

  code_size = refactored_code.size
  elapsed_time = end_time - start_time
  speed = elapsed_time.positive? ? (code_size / elapsed_time) : 0

  puts "\nFile: #{path}"
  puts "Code size: #{code_size} characters"
  puts "Elapsed time: #{elapsed_time.round(2)} seconds"
  puts "Speed: #{speed.round(2)} characters per second"

  if original_code == refactored_code
    puts 'No changes made.'
    next
  end

  is_git_repository = system(
    'git ls-files --error-unmatch ' \
    "#{Shellwords.shellescape(path)} > #{File::NULL} 2>&1"
  )

  backup_file_path = "#{path}.bak"
  unless is_git_repository
    begin
      File.binwrite(backup_file_path, original_code)
    rescue SystemCallError => e
      warn "Failed to write backup file #{backup_file_path}: #{e.message}"
      exit 1
    end
  end

  begin
    File.binwrite(path, refactored_code)
  rescue SystemCallError => e
    warn "Failed to write refactored file #{path}: #{e.message}"
    exit 1
  end

  if is_git_repository
    system(
      "git diff -w #{Shellwords.shellescape(path)}"
    )
  else
    system(
      "diff -u --color #{Shellwords.shellescape(backup_file_path)} " \
      "#{Shellwords.shellescape(path)}"
    )
  end
end
