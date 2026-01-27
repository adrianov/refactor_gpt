#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Superagent - Automated code agent with multi-model fallback and verification
# Copyright 2026 Peter Adrianov
# Email: peter.adrianov@gmail.com
# Telegram: @adrianov
#
# Executes agent commands across multiple AI models sequentially,
# automatically verifying results and retrying with fix instructions when verification fails.

completion_notifier_path = File.join(__dir__, 'lib', 'completion_notifier.rb')
begin
  require_relative 'lib/completion_notifier' if File.exist?(completion_notifier_path)
rescue LoadError, StandardError
  # Ignore if completion_notifier is not available
end
require 'colorize'
require 'reline'
require 'open3'

# Handles all output formatting and display operations
class Display
  def timestamped_puts(*args)
    args.each do |arg|
      time_str = Time.now.strftime('%Y-%m-%d %H:%M:%S')
      puts "[#{time_str}] #{arg}"
    end
  end

  def display_git_status
    return unless git_repo?

    status = `git status --short 2>&1`.strip
    return if status.empty?

    timestamped_puts 'Git status:'.cyan
    status.each_line { |line| timestamped_puts "  #{line.chomp}" }
    timestamped_puts ''
  end

  def display_start_message(user_request)
    timestamped_puts "\nSuperagent:".cyan
    timestamped_puts "#{user_request}\n".yellow
    timestamped_puts ''
    display_git_status
  end

  def display_attempt_header(model, index, total)
    timestamped_puts "--- Attempt #{index + 1}/#{total}: #{model} ---".blue
    timestamped_puts ''
  end

  def display_verification_result(verified, description, context = '')
    prefix = verified ? '✓ Passed' : '✗ Failed'
    suffix = context.empty? ? '' : " #{context}"

    message = if description && !description.empty?
                "#{prefix}#{suffix}: #{description}"
              elsif verified
                "#{prefix}#{suffix}! Success."
              else
                default = context.empty? ? 'Retrying...' : 'Next model...'
                "#{prefix}#{suffix}! #{default}"
              end

    color = verified ? :green : :yellow
    timestamped_puts message.send(color)
  end

  def display_total_runtime(start_time)
    return unless start_time

    elapsed = Time.now - start_time
    timestamped_puts "Run time: #{format_duration(elapsed)}".cyan
  end

  def display_agent_failure
    timestamped_puts 'Agent failed. Next model...'.yellow
    timestamped_puts ''
  end

  def display_all_attempts_failed
    timestamped_puts 'All attempts failed.'.red
  end

  def git_repo?
    system("git rev-parse --is-inside-work-tree > #{File::NULL} 2>&1")
  end

  def format_duration(seconds)
    "#{(seconds / 60).to_i}m #{(seconds % 60).to_i}s"
  end
end

# Handles reading user requests from various sources
class RequestReader
  def initialize(display)
    @display = display
  end

  def read_from_argv
    ARGV.join(' ') unless ARGV.empty?
  end

  def read_from_stdin
    $stdin.read.strip unless $stdin.tty?
  end

  def read_interactive
    @display.timestamped_puts 'Enter your request:'.cyan
    @display.timestamped_puts '(Press Enter twice or Ctrl+D to submit)'
    @display.timestamped_puts ''

    lines = []
    loop do
      line = read_interactive_line(lines)
      return nil if line.nil?
      break if line == :done
      next if line == :continue

      lines << line
    end
    lines.join("\n")
  end

  def read_interactive_line(lines)
    line = Reline.readline(lines.empty? ? '> ' : '  ', true)
    return nil if line.nil?

    line = line.strip
    return :done if line.empty? && !lines.empty?
    return :continue if line.empty?

    line
  end

  def read
    read_from_argv || read_from_stdin || read_interactive
  end

  def validate(user_request)
    return true if user_request && !user_request.strip.empty?

    @display.timestamped_puts 'No request provided. Exiting.'.yellow
    exit 1
  end
end

# Handles agent command execution with retry logic
class AgentExecutor
  def initialize(display)
    @display = display
  end

  def wrap_prompt(prompt)
    <<~HEREDOC
      IMPORTANT: This agent is running in non-interactive mode. Do not ask questions, request user input, or wait for confirmation. Work autonomously using available information and make reasonable decisions based on context. Execute tasks directly without seeking clarification.

      #{prompt}
    HEREDOC
  end

  def retryable_network_error?(output)
    return false if output.nil? || output.empty?

    output.include?('CANCEL') || output.include?('canceled') ||
      output.include?('stream closed') || output.include?('0x8') ||
      output.include?('http/2 stream closed') || output.include?('Connection stalled')
  end

  def run(model, prompt, max_retries: 3, base_delay: 1)
    wrapped_prompt = wrap_prompt(prompt)
    retries = 0

    loop do
      @display.timestamped_puts "Running: agent --print --model #{model} '#{prompt[0..50]}...'"
      stdout, stderr, status = Open3.capture3('agent', '--print', '--model', model, wrapped_prompt)
      output = stdout + stderr
      output.each_line { |line| @display.timestamped_puts line.chomp }

      return [status.success?, output] if status.success?

      if retryable_network_error?(output) && retries < max_retries
        retries += 1
        delay = base_delay * (2**(retries - 1))
        @display.timestamped_puts "⚠️  Network error detected, retrying in #{delay}s... (#{retries}/#{max_retries})".yellow
        sleep(delay)
        next
      end

      return [false, output]
    end
  end
end

# Handles verification prompts and response parsing
class VerificationHandler
  def initialize(display, agent_executor)
    @display = display
    @agent_executor = agent_executor
    @verify_gpt_path = File.join(__dir__, 'verify_gpt.rb')
  end

  def verify_gpt_available?
    File.exist?(@verify_gpt_path)
  end

  def build_fix_prompt(user_request)
    <<~HEREDOC
      Original user request: #{user_request}

      The previous attempt did not fully solve the request or introduced issues. Please fix the implementation.

      Review the current state of the codebase, identify what's missing or incorrect, and make the necessary corrections.
    HEREDOC
  end

  def parse_response(response)
    return [false, nil] if response.nil? || response.strip.empty?

    normalized = response.strip
    upcased = normalized.upcase

    # Prioritize start_with? for cleaner parsing
    return parse_yes_response(normalized) if upcased.start_with?('YES')
    return parse_no_response(normalized) if upcased.start_with?('NO')

    yes_index = upcased.index(/\bYES\b/)
    no_index = upcased.index(/\bNO\b/)

    return parse_no_response(normalized) if no_index && (yes_index.nil? || no_index < yes_index)
    return parse_yes_response(normalized) if yes_index && (no_index.nil? || yes_index < no_index)

    [false, nil]
  end

  def parse_no_response(normalized)
    match = normalized.match(/\bNO\s*:?\s*(.+)/i)
    [false, match ? match[1].strip : 'Failed']
  end

  def parse_yes_response(normalized)
    match = normalized.match(/\bYES\s*:?\s*(.+)/i)
    [true, match ? match[1].strip : 'Passed']
  end

  def run_verification_with_verify_gpt(user_request)
    @display.timestamped_puts 'Verifying...'.blue
    @display.timestamped_puts "Running: verify_gpt.rb '#{user_request[0..50]}...'"

    # Use Open3.capture3 to run verify_gpt.rb and capture its output
    stdout, stderr, status = Open3.capture3('ruby', @verify_gpt_path, user_request)
    output = stdout + stderr
    output.each_line { |line| @display.timestamped_puts line.chomp }

    unless status.success?
      return [false, 'verify_gpt.rb failed']
    end

    # verify_gpt.rb outputs "YES: description" or "NO: description"
    verified, description = parse_response(stdout.strip)
    [verified, description || 'Failed']
  end

  def run_verification(model, user_request)
    return run_verification_with_verify_gpt(user_request) if verify_gpt_available?

    @display.timestamped_puts 'verify_gpt.rb not found.'.yellow
    [true, 'verify_gpt.rb not found, assuming success']
  end

  def attempt_retry_with_fix(model, user_request)
    fix_prompt = build_fix_prompt(user_request)
    @display.timestamped_puts "Retrying #{model} with fix...".blue
    @display.timestamped_puts ''

    success, _output = @agent_executor.run(model, fix_prompt)
    return [false, nil] unless success

    run_verification(model, user_request)
  end
end

# Main orchestrator class for superagent execution
class Superagent
  MODELS = %w[
    auto
    gemini-3-flash
    claude-4.5-sonnet
    claude-4.5-opus
  ].freeze

  def initialize(display: Display.new, request_reader: nil, agent_executor: nil, verification_handler: nil)
    @display = display
    @request_reader = request_reader || RequestReader.new(@display)
    @agent_executor = agent_executor || AgentExecutor.new(@display)
    @verification_handler = verification_handler || VerificationHandler.new(@display, @agent_executor)
    @start_time = nil
  end

  def run
    @start_time = Time.now
    user_request = @request_reader.read
    @request_reader.validate(user_request)
    @display.display_start_message(user_request)

    MODELS.each_with_index do |model, index|
      @display.display_attempt_header(model, index, MODELS.size)

      success, _output = @agent_executor.run(model, user_request)
      unless success
        @display.display_agent_failure
        next
      end

      result = process_model_attempt(model, user_request)
      return if result == :success
    end

    @display.display_all_attempts_failed
    @display.display_total_runtime(@start_time)
    @display.display_git_status
    exit 1
  end

  private

  def process_model_attempt(model, user_request)
    verified, description = @verification_handler.run_verification(model, user_request)
    @display.timestamped_puts ''

    return handle_verification_success(description) if verified

    @display.display_verification_result(false, description)
    @display.timestamped_puts ''

    verified, fix_description = @verification_handler.attempt_retry_with_fix(model, user_request)
    @display.timestamped_puts ''

    return handle_verification_success(fix_description, 'after retry') if verified

    @display.display_verification_result(false, fix_description, 'after retry')
    @display.timestamped_puts ''
    :continue
  end

  def handle_verification_success(description, context = '')
    @display.display_verification_result(true, description, context)
    @display.display_total_runtime(@start_time)
    @display.display_git_status
    exit 0
  end
end

if __FILE__ == $PROGRAM_NAME
  if defined?(CompletionNotifier) && CompletionNotifier.respond_to?(:wrap_main)
    CompletionNotifier.wrap_main do
      Superagent.new.run
    end
  else
    Superagent.new.run
  end
end
