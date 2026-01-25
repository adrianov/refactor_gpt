#!/usr/bin/env ruby
# frozen_string_literal: true

require "colorize"
require_relative "lib/openai_client"
require_relative "lib/agents_file_handler"
require_relative "lib/refactor_gpt_utils"
require "shellwords"
require "oj"
require "tempfile"

# Class to interact with OpenAI API
class OpenAi
  include AgentsFileHandler

  def initialize(model: nil, debug: false)
    @debug = debug
    @env_vars = load_env_vars
    setup_config(model)
    setup_clients
  end

  # Method to send prompts to OpenAI and get a response
  def ask(prompts, json: false)
    # This ask method is used by the first client in the chain for generic requests
    @clients.first.ask(prompts, json: json)
  end

  # Method to refactor code based on user instructions
  def refactor(file_codes, user_instruction = nil)
    current_file_codes = file_codes.dup
    any_stage_successful = false
    assessment = {"satisfied" => false, "warnings" => []}

    @clients.each_with_index do |client, index|
      refactored_files = process_stage(client, index, current_file_codes, user_instruction)

      if refactored_files.any?
        any_stage_successful = true
        refactored_files.each { |path, new_code| current_file_codes[path] = new_code }
      end

      # Skip assessment if no files changed and not the last stage
      next if refactored_files.empty? && !last_stage?(index)

      assessment = perform_assessment(file_codes, current_file_codes, user_instruction, client: client)

      if assessment["warnings"]&.any? && refactored_files.any?
        fixed_files = attempt_to_fix_warnings(client, current_file_codes, assessment["warnings"], user_instruction)
        unless fixed_files.empty?
          fixed_files.each { |path, code| current_file_codes[path] = code }
          assessment = perform_assessment(file_codes, current_file_codes, user_instruction, client: client)
        end
      end

      break if assessment["satisfied"] && (assessment["warnings"].nil? || assessment["warnings"].empty?)
      break if last_stage?(index)
    end

    warn "Warning: All stages failed to produce output. Returning original files." unless any_stage_successful
    build_final_response(current_file_codes)
  end

  private

  def attempt_to_fix_warnings(client, current_file_codes, warnings, user_instruction)
    model_name = client.instance_variable_get(:@model)
    puts "Attempting to fix warnings with #{model_name}...".blue

    warning_text = warnings.map { |w| "- #{w["message"]} (probability: #{w["probability"]})" }.join("\n")
    fix_instruction = "Fix these issues from the previous refactoring step:\n#{warning_text}"
    fix_instruction += "\n\nOriginal instruction: #{user_instruction}" if user_instruction

    raw_response = client.ask(refactor_messages(current_file_codes, fix_instruction))
    ResponseParser.parse_files_from_response(raw_response, current_file_codes.keys, exit_on_error: false)
  end

  def last_stage?(index)
    index == @clients.size - 1
  end

  def perform_assessment(original_file_codes, current_file_codes, user_instruction, client: nil)
    client ||= @clients.first
    model_name = client.instance_variable_get(:@model)
    puts "--- Assessing if instruction is fulfilled (#{model_name}) ---".blue

    prompt = build_assessment_prompt(original_file_codes, current_file_codes, user_instruction)
    messages = [
      {role: "system", content: "You are an expert code reviewer. Assess if the user's refactoring instruction " \
                               "has been fully fulfilled. Respond ONLY with a JSON object: " \
                               "{\"satisfied\": true/false, \"reason\": \"brief explanation\", " \
                               "\"warnings\": [{\"message\": \"...\", \"probability\": 0..1}]}"},
      {role: "user", content: prompt}
    ]

    response = client.ask(messages, json: true, title: "Assessing refactoring".cyan)
    result = ResponseParser.extract_json(response)

    display_assessment_result(result)
    result
  rescue => e
    warn "Warning: Self-assessment failed: #{e.message}"
    {"satisfied" => false, "reason" => "Assessment failed: #{e.message}", "warnings" => []}
  end

  def display_assessment_result(result)
    status_color = result["satisfied"] ? :green : :yellow
    puts "Assessment: #{result["reason"]}".colorize(status_color)

    return unless result["warnings"]&.any?

    puts "Warnings:".yellow
    result["warnings"].each do |warning|
      prob = warning["probability"] || 0
      puts "  - #{warning["message"]} (probability: #{prob})".yellow
    end
  end

  def build_assessment_prompt(original_file_codes, current_file_codes, user_instruction)
    instruction = user_instruction || DEFAULT_USER_INSTRUCTION
    prompt = "User Instruction: #{instruction}\n\n"
    prompt += "Review the following changes (in unified diff format) and determine if they fulfill the instruction:\n\n"

    current_file_codes.each do |path, current_code|
      original_code = original_file_codes[path]
      next if original_code == current_code

      prompt += generate_diff(path, original_code, current_code)
      prompt += "\n"
    end
    prompt
  end

  def generate_diff(path, original, current)
    Tempfile.create(["original", File.extname(path)]) do |f1|
      f1.binmode
      f1.write(original)
      f1.close
      Tempfile.create(["current", File.extname(path)]) do |f2|
        f2.binmode
        f2.write(current)
        f2.close
        diff = `diff -u #{Shellwords.shellescape(f1.path)} #{Shellwords.shellescape(f2.path)}`
        # Clean up the diff header to show the actual filename
        diff.sub(/^--- .*\n\+\+\+ .*\n/, "--- a/#{path}\n+++ b/#{path}\n")
      end
    end
  rescue => e
    warn "Warning: Diff generation failed for #{path}: #{e.message}"
    "--- a/#{path}\n+++ b/#{path}\n@@ -0,0 +0,0 @@\n(Diff failed, original and refactored versions differ)\n"
  end

  def process_stage(client, index, current_file_codes, user_instruction)
    display_stage_info(client, index)
    raw_response = client.ask(refactor_messages(current_file_codes, user_instruction))
    refactored_files = ResponseParser.parse_files_from_response(raw_response, current_file_codes.keys,
      exit_on_error: false)

    if refactored_files.empty?
      model_name = client.instance_variable_get(:@model)
      warn "Warning: Stage #{index + 1} (#{model_name}) returned no refactored files."
    end

    refactored_files
  end

  def setup_config(model)
    @base_url = fetch_config("REFACTOR_BASE_URL", "OPENAI_BASE_URL")
    @api_key = fetch_config("REFACTOR_ACCESS_TOKEN", "OPENAI_ACCESS_TOKEN")
    @models = [
      fetch_env_var("REFACTOR_MODEL_1"),
      fetch_env_var("REFACTOR_MODEL_2"),
      fetch_env_var("REFACTOR_MODEL_3")
    ].compact

    @models = [model || fetch_env_var("DEFAULT_MODEL") || OpenAiClient::DEFAULT_MODEL] if @models.empty?
  end

  def fetch_config(primary, secondary)
    fetch_env_var(primary) || fetch_env_var(secondary)
  end

  def fetch_env_var(key)
    @env_vars[key] || ENV[key]
  end

  def setup_clients
    @clients = @models.map do |m|
      OpenAiClient.new(
        model: m,
        debug: @debug,
        progress_title: "Refactoring code (#{m})".cyan,
        api_base_url: @base_url,
        api_key: @api_key
      )
    end
  end

  def display_stage_info(client, index)
    return unless @debug || @clients.size > 1

    model_name = client.instance_variable_get(:@model)
    puts "\n--- Stage #{index + 1}/#{@clients.size}: Refactoring with #{model_name} ---".blue
  end

  def refactor_messages(file_codes, user_instruction)
    [
      {role: "system", content: build_system_instruction},
      {role: "user", content: build_refactor_prompt(file_codes, user_instruction)}
    ]
  end

  def build_final_response(file_codes)
    file_codes.map do |path, code|
      "<full_file_contents_to_replace filename=\"#{path}\">#{code}</full_file_contents_to_replace>"
    end.join("\n")
  end

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
      <full_file_contents_to_replace filename="[REPLACE_WITH_ACTUAL_FILE_PATH]">complete file content</full_file_contents_to_replace>

      The <full_file_contents_to_replace> tags and the complete file content between them must be
      output on separate lines. The file content between the opening and
      closing tags can span multiple lines and must include every line of the
      file exactly as it should appear.

      Files provided as context use this format in the prompt and must NOT be
      returned:
      <content filename="path/to/file.rb">complete file content</content>

      Content between <full_file_contents_to_replace> and </full_file_contents_to_replace> tags MUST be the complete file
      content from the first line to the last line. Never abbreviate, cut, or
      use placeholders like "...". Always include all lines of the file.

      Content between <content> and </content> tags in the prompt is provided as
      reference only. Never return files that were marked with <content>. Only
      return files you actually modify.

      ALWAYS use <full_file_contents_to_replace> tags for ALL returned files, including single-file responses.
      Never return raw text without tags. This is required for both single-file and multi-file responses.

      CRITICAL: DO NOT create new files. Only refactor the files provided in the prompt.
      If you think a new file is needed, refactor the existing code instead.

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

# Main runner class
class RefactorGptRunner
  def initialize
    @file_paths = []
    @user_instruction_parts = []
  end

  def run(args)
    @debug = args.include?("--debug") || args.include?("-d")
    parse_arguments(args)
    validate_files

    file_codes = read_files

    raw_response, elapsed_time = with_timing do
      OpenAi.new(debug: @debug).refactor(file_codes, user_instruction).to_s
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
      next if ["--debug", "-d"].include?(arg)

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
      file_codes[file_path] = File.binread(file_path).force_encoding("UTF-8")
    rescue SystemCallError => e
      warn "Failed to read file #{file_path}: #{e.message}"
      exit 1
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
