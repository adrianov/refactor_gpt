#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/loader"
require "colorize"
require "shellwords"
require "oj"
require "tempfile"

# Multi-stage OpenAI-compatible refactor client with assessment and warning fixes.
class OpenAi
  include AgentsFileHandler
  include RefactorAssessment

  def initialize(model: nil, debug: false)
    @debug = debug
    @env_vars = load_env_vars
    setup_config(model)
    setup_clients
  end

  def ask(prompts, json: false)
    @clients.first.ask(prompts, json: json)
  end

  def refactor(file_codes, user_instruction = nil)
    current_file_codes = file_codes.dup
    any_stage_successful = apply_client_stages(file_codes, current_file_codes, user_instruction)
    warn 'Warning: All stages failed to produce output. Returning original files.' unless any_stage_successful
    build_final_response(current_file_codes)
  end

  private

  def apply_client_stages(original_codes, current_file_codes, user_instruction)
    any_success = false
    @clients.each_with_index do |client, index|
      changed = process_stage(client, index, current_file_codes, user_instruction)
      any_success ||= changed.any?
      changed.each { |path, code| current_file_codes[path] = code }

      assessment = assess_stage(client, index, original_codes, current_file_codes, user_instruction, changed)
      break if satisfied?(assessment) || last_stage?(index)

      puts 'Proceeding to higher agent as task is not fully solved or critical warnings exist.'.yellow
    end
    any_success
  end

  def assess_stage(client, index, original_codes, current_file_codes, user_instruction, changed)
    return {'satisfied' => false, 'warnings' => []} if changed.empty? && !last_stage?(index)

    assessment = perform_assessment(original_codes, current_file_codes, user_instruction, client: client)
    return assessment unless assessment['warnings']&.any? && changed.any?

    fix_warnings_if_needed(client, original_codes, current_file_codes, assessment, user_instruction)
    perform_assessment(original_codes, current_file_codes, user_instruction, client: client)
  end

  def process_stage(client, index, current_file_codes, user_instruction)
    display_stage_info(client, index)
    model_name = client.instance_variable_get(:@model)
    raw_response = client.ask(refactor_messages(current_file_codes, user_instruction),
      title: "Refactoring with #{model_name}".cyan)
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
    @models = load_models(model)
  end

  def load_models(model)
    models = [
      fetch_env_var("REFACTOR_MODEL_1"),
      fetch_env_var("REFACTOR_MODEL_2"),
      fetch_env_var("REFACTOR_MODEL_3")
    ].compact

    return models unless models.empty?

    [model || fetch_env_var("DEFAULT_MODEL") || OpenAiClient::DEFAULT_MODEL]
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
    [refactor_output_format_instruction, refactor_behavior_instruction].join("\n\n")
  end

  def refactor_output_format_instruction
    (<<~HEREDOC
      Return refactored files using this format:
      <full_file_contents_to_replace filename="[REPLACE_WITH_ACTUAL_FILE_PATH]">complete file content</full_file_contents_to_replace>

      The <full_file_contents_to_replace> tags and the complete file content between them must be
      output on separate lines. The file content between the opening and
      closing tags can span multiple lines and must include every line of the
      file exactly as it should appear.

      Files provided as context use this format in the prompt and must NOT be
      returned:
      <content filename="path/to/file.rb">
      complete file content
      </content>

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
    HEREDOC
    ).strip
  end

  # Instruction for how to refactor (behavior only). Edit this when improving wording for humans/LLMs.
  def refactor_behavior_instruction
    (<<~HEREDOC
      Apply changes that make code easier to edit and understand for both humans and LLMs:
      improve structure and remove duplication; use clear, literal names; keep methods and
      blocks small and focused; prefer explicit logic over clever or implicit code; keep
      formatting and structure consistent so readers and tools can parse reliably.
      Preserve all existing comments unless they describe code you change or you implement
      a TODO. When making bug fixes or requested changes, keep the diff minimal. Never
      suggest purely stylistic changes (quote style, alternative method names). Only make
      necessary structural improvements.
    HEREDOC
    ).strip
  end

  def build_refactor_prompt(file_codes, user_instruction)
    <<~HEREDOC
      #{user_instruction || load_refactor_md}

      Files are provided below using <content> tags. You may use some files only as
      context and leave them unchanged. Only return files you actually modify.

      #{file_codes.map { |path, code| "<content filename=\"#{path}\">\n#{code}\n</content>" }.join("\n\n")}
    HEREDOC
  end
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
    process_refactoring(file_codes)
  end

  private

  def process_refactoring(file_codes)
    raw_response, elapsed_time = with_timing do
      OpenAi.new(debug: @debug).refactor(file_codes, user_instruction).to_s
    end

    refactored_files = ResponseParser.parse_files_from_response(raw_response, @file_paths)
    FileProcessor.new(file_codes).process_refactored_files(refactored_files, elapsed_time)
  end

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
CompletionNotifier.setup_exit_hook

if ARGV.empty?
  puts(
    "Usage: #{File.basename($PROGRAM_NAME)} <file1> [file2 ...] " \
    '["Instructions what to do."]'
  )
  exit 0
end

RefactorGptRunner.new.run(ARGV)
