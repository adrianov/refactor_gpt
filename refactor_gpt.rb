#!/usr/bin/env ruby
# frozen_string_literal: true

require "colorize"
require_relative "lib/openai_client"
require_relative "lib/agents_file_handler"
require "shellwords"
require "json"
require "digest"

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
    agents_content = load_agents_file
    has_agents = !agents_content.empty?

    system_instruction_parts = []

    system_instruction_parts << <<~HEREDOC
      Return a JSON response with patch data in unified diff format. Do not
      return full file contents. Generate patches in compact patch format
      without context lines unless necessary. Follow standard unified diff
      format with @@ line numbers @@.
      Strictly preserve existing comments unless implemented TODOs or changed
      code fragment business logic, if not asked otherwise. When making bug fixes
      or applying specific requested changes, keep the diff as small as
      reasonably possible in terms of changed lines.
      Do not suggest changes that are purely stylistic choices - e.g. type of
      quotes, alternative method names. Only suggest real structural changes.
    HEREDOC

    system_instruction_parts << "Follow Ruby development guidelines from AGENTS.md." if has_agents

    system_instruction_parts << <<~HEREDOC

      When multiple files are provided, respond with JSON in the following format:
      {
        "patches": [
          {
            "path": "<relative-or-given-path-1>",
            "patch": "<unified diff patch content>"
          },
          {
            "path": "<relative-or-given-path-2>",
            "patch": "<unified diff patch content>"
          }
        ]
      }

      Some files may be used only as context and leave them unchanged - only
      include files that need changes in the patches array.
      If no changes are needed, return an empty patches array.
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
      "File: #{path}\n#{code}"
    end.join("\n\n")

    prompt = <<~HEREDOC
      #{user_instruction || default_user_instruction}

      You may use some files only as context and leave them unchanged.

      #{files_block}
    HEREDOC

    ask(
      [
        {role: "system", content: system_instruction},
        {role: "user", content: prompt}
      ]
    )
  end
end

class PatchApplicator
  def initialize(file_codes)
    @file_codes = file_codes
  end

  def apply_patches(patch_data)
    return {} if patch_data["patches"].nil? || patch_data["patches"].empty?

    patch_data["patches"].each_with_object({}) do |patch_info, applied|
      path = patch_info["path"]
      patch_content = patch_info["patch"]

      next unless path && patch_content && @file_codes.key?(path)

      original_content = @file_codes[path]
      patched_content = apply_unified_diff(original_content, patch_content)
      applied[path] = patched_content if patched_content
    end
  end

  private

  def apply_unified_diff(original_content, patch_content)
    original_lines = original_content.split("\n")
    patched_lines = original_lines.dup
    current_line = 0

    patch_content.each_line do |line|
      case line[0]
      when "@@"
        # Parse hunk header: @@ -start,count +start,count @@
        matches = line.match(/@@\s*-\d+(?:,\d+)?\s*\+(\d+)(?:,\d+)?\s*@@/)
        if matches
          current_line = matches[1].to_i - 1  # Convert to 0-based index
        end
      when " "
        # Context line - just advance
        current_line += 1 if current_line < patched_lines.size
      when "-"
        # Deletion line
        patched_lines.delete_at(current_line)
      when "+"
        # Addition line
        patched_lines.insert(current_line, line[1..-1])
        current_line += 1
      end
    end

    patched_lines.join("\n")
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
  puts "No valid files provided."
  exit 1
end

user_instruction = user_instruction_parts.join(" ") unless user_instruction_parts.empty?

file_codes = {}

file_paths.each do |file_path|
  begin
    code = File.binread(file_path).force_encoding("UTF-8")
  rescue SystemCallError => e
    warn "Failed to read file #{file_path}: #{e.message}"
    exit 1
  end
  file_codes[file_path] = code
end

start_time = Time.now

raw_response = OpenAi.new.refactor(file_codes, user_instruction).to_s

end_time = Time.now

def parse_patches_from_response(response)
  begin
    json_response = JSON.parse(response)
    if json_response["patches"] && json_response["patches"].is_a?(Array)
      return json_response
    end
  rescue JSON::ParserError
    # Fallback - try to extract patch if response looks like a single patch
    return { "patches" => [{ "path" => "", "patch" => response }] }
  end
  { "patches" => [] }
end

patch_data = parse_patches_from_response(raw_response)
applier = PatchApplicator.new(file_codes)
refactored_files = applier.apply_patches(patch_data)

refactored_files.each do |path, content|
  next unless file_codes.key?(path)

  content += "\n" if !content.empty? && content[-1] != "\n"

  original_code = file_codes[path]
  refactored_code = content

  puts "\nFile: #{path}"
  puts "Code size: #{refactored_code.size} characters"
  puts "Elapsed time: #{(end_time - start_time).round(2)} seconds"
  elapsed = end_time - start_time
  speed = elapsed.positive? ? (refactored_code.size / elapsed).round(2) : 0
  puts "Speed: #{speed} characters per second"

  if original_code == refactored_code
    puts "No changes made."
    next
  end

  is_git_repository = system(
    "git ls-files --error-unmatch " \
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

if refactored_files.empty?
  puts "\nNo files were modified."
end
