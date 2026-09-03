#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/loader"
require "colorize"
require "shellwords"
require "oj"
require "tempfile"

# OpenRouter refactor client with assessment and warning fixes.
class RefactorLlm
  include AgentsFileHandler
  include RefactorAssessment
  include RefactorPrompt

  def initialize(model: nil, debug: false)
    @debug = debug
    chosen = model || OpenrouterClient.default_model
    @clients = [OpenrouterClient.new(model: chosen, debug: @debug,
      progress_title: "Refactoring code (#{chosen})".cyan)]
  end

  def ask(prompts, json: false)
    @clients.first.ask(prompts, json: json)
  end

  def refactor(file_codes, user_instruction = nil)
    current_file_codes = file_codes.dup
    unless apply_client_stages(file_codes, current_file_codes, user_instruction)
      warn 'Warning: All stages failed to produce output. Returning original files.'
    end
    build_final_response(current_file_codes)
  end

  private

  def apply_client_stages(original_codes, current_file_codes, user_instruction)
    any_success = false
    @clients.each_with_index do |client, index|
      changed = process_stage(client, index, current_file_codes, user_instruction)
      any_success ||= changed.any?
      changed.each { |path, code| current_file_codes[path] = code }

      break if satisfied?(assess_stage(client, index, original_codes, current_file_codes, user_instruction, changed)) ||
        last_stage?(index)

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
    refactored_files = ResponseParser.parse_files_from_response(
      client.ask(
        refactor_messages(current_file_codes, user_instruction),
        title: "Refactoring with #{client.instance_variable_get(:@model)}".cyan
      ),
      current_file_codes.keys,
      exit_on_error: false
    )

    if refactored_files.empty?
      model_name = client.instance_variable_get(:@model)
      warn "Warning: Stage #{index + 1} (#{model_name}) returned no refactored files."
    end

    refactored_files
  end

  def display_stage_info(client, index)
    return unless @debug || @clients.size > 1

    puts(
      "\n--- Stage #{index + 1}/#{@clients.size}: " \
      "Refactoring with #{client.instance_variable_get(:@model)} ---".blue
    )
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

    process_refactoring(read_files)
  end

  private

  def process_refactoring(file_codes)
    raw_response, elapsed_time = with_timing do
      RefactorLlm.new(debug: @debug).refactor(file_codes, user_instruction).to_s
    end

    FileProcessor.new(file_codes).process_refactored_files(
      ResponseParser.parse_files_from_response(raw_response, @file_paths),
      elapsed_time
    )
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
