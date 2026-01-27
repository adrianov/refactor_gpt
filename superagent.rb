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
require 'timeout'
require 'rbconfig'

# Handles all output formatting and display operations
class Display
  def timestamped_puts(*args)
    args.each do |arg|
      time = Time.now.strftime('%Y-%m-%d %H:%M:%S')
      puts "[#{time}] #{arg}"
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

  def display_start_message(req)
    timestamped_puts "\nSuperagent:".cyan
    timestamped_puts req.yellow
    timestamped_puts ''
    display_git_status
  end

  def display_attempt_header(model, idx, total)
    timestamped_puts "--- Attempt #{idx + 1}/#{total}: #{model} ---".blue
    timestamped_puts ''
  end

  def display_verification_result(verified, desc, context = '')
    prefix = verified ? '✓ Passed' : '✗ Failed'
    suffix = context.empty? ? '' : " #{context}"

    if desc && !desc.empty?
      if desc.include?("\n")
        timestamped_puts "#{prefix}#{suffix}:".send(verified ? :green : :yellow)
        desc.each_line { |line| timestamped_puts "  #{line.chomp}" }
      else
        timestamped_puts "#{prefix}#{suffix}: #{desc}".send(verified ? :green : :yellow)
      end
    elsif verified
      timestamped_puts "#{prefix}#{suffix}! Success.".send(:green)
    else
      timestamped_puts "#{prefix}#{suffix}! #{context.empty? ? 'Retrying...' : 'Next...'}".send(:yellow)
    end
  end

  def display_total_runtime(start_time)
    return unless start_time

    elapsed = Time.now - start_time
    timestamped_puts "Run time: #{format_duration(elapsed)}".cyan
  end

  def display_agent_failure(output = nil)
    timestamped_puts 'Agent failed. Next...'.yellow
    if output && !output.strip.empty?
      timestamped_puts ''
      timestamped_puts 'Agent output:'.yellow
      output.each_line { |line| timestamped_puts line.chomp }
    end
    timestamped_puts ''
  end

  def display_all_attempts_failed
    timestamped_puts 'All attempts failed.'.red
  end

  def git_repo?
    system("git rev-parse --is-inside-work-tree > #{File::NULL} 2>&1")
  end

  def format_duration(sec)
    "#{(sec / 60).to_i}m #{(sec % 60).to_i}s"
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
    @display.timestamped_puts 'Enter request:'.cyan
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

  def validate(req)
    return true if req && !req.strip.empty?

    @display.timestamped_puts 'No request provided. Exiting.'.yellow
    exit 1
  end
end

# Handles agent command execution with retry logic
class AgentExecutor
  EXECUTION_TIMEOUT = 300
  TEST_RUNNERS = %w[rspec minitest test-unit cucumber jest mocha pytest].freeze

  def initialize(display)
    @display = display
  end

  def test_runner_running?
    return false unless RbConfig::CONFIG['host_os'] =~ /linux|darwin|bsd/

    TEST_RUNNERS.any? do |runner|
      system("pgrep -f #{runner} > #{File::NULL} 2>&1")
    end
  end

  def wrap_prompt(p)
    <<~HEREDOC
      IMPORTANT: This agent is running in non-interactive mode. Do not ask questions, request user input, or wait for confirmation. Work autonomously using available information and make reasonable decisions based on context. Execute tasks directly without seeking clarification.

      #{p}
    HEREDOC
  end

  def retryable_network_error?(output)
    return false if output.nil? || output.empty?

    output.include?('CANCEL') || output.include?('canceled') ||
      output.include?('stream closed') || output.include?('0x8') ||
      output.include?('http/2 stream closed') || output.include?('Connection stalled')
  end

  def run(model, p, max_retries: 3, base_delay: 1)
    wrapped = wrap_prompt(p)
    retries = 0

    loop do
      @display.timestamped_puts "Running: agent --model #{model} '#{p[0..50]}...'"
      stdout, stderr, status = nil
      begin
        if test_runner_running?
          stdout, stderr, status = Open3.capture3('agent', '--print', '--model', model, wrapped)
        else
          Timeout.timeout(EXECUTION_TIMEOUT) do
            stdout, stderr, status = Open3.capture3('agent', '--print', '--model', model, wrapped)
          end
        end
      rescue Timeout::Error
        @display.timestamped_puts "❌ Agent timed out after #{EXECUTION_TIMEOUT}s".red
        return [false, "Timeout after #{EXECUTION_TIMEOUT}s"]
      end

      output = stdout + stderr
      output.each_line { |line| @display.timestamped_puts line.chomp }

      return [status.success?, output] if status.success?

      if retryable_network_error?(output) && retries < max_retries
        retries += 1
        delay = base_delay * (2**(retries - 1))
        @display.timestamped_puts "⚠️  Network error, retrying in #{delay}s... (#{retries}/#{max_retries})".yellow
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

  def build_fix_prompt(req)
    <<~HEREDOC
      Original request: #{req}

      The previous attempt failed. Please fix the implementation.

      Review the codebase and make the necessary corrections.
    HEREDOC
  end

  def parse_res(res)
    return [false, res] if res.nil? || res.strip.empty?

    n = res.strip
    up = n.upcase

    return parse_yes_res(n) if up.start_with?('YES')
    return parse_no_res(n) if up.start_with?('NO')

    yes_idx = up.index(/\bYES\b/)
    no_idx = up.index(/\bNO\b/)

    return parse_no_res(n) if no_idx && (yes_idx.nil? || no_idx < yes_idx)
    return parse_yes_res(n) if yes_idx && (no_idx.nil? || yes_idx < no_idx)

    [false, res]
  end

  def parse_no_res(n)
    m = n.match(/\bNO\s*:?\s*(.+)/i)
    [false, m ? m[1].strip : 'Failed']
  end

  def parse_yes_res(n)
    m = n.match(/\bYES\s*:?\s*(.+)/i)
    [true, m ? m[1].strip : 'Passed']
  end

  def run_verify_gpt(req)
    @display.timestamped_puts 'Verifying...'.blue
    @display.timestamped_puts "Running: verify_gpt.rb '#{req[0..50]}...'"

    stdout, stderr, status = Open3.capture3('ruby', @verify_gpt_path, req)
    output = stdout + stderr
    output.each_line { |line| @display.timestamped_puts line.chomp }

    return [false, 'verify_gpt.rb failed'] unless status.success?

    verified, desc = parse_res(stdout.strip)
    [verified, desc || 'Failed']
  end

  def run_verification(model, req)
    return run_verify_gpt(req) if verify_gpt_available?

    @display.timestamped_puts 'verify_gpt.rb not found.'.yellow
    [true, 'verify_gpt.rb not found, assuming success']
  end

  def retry_with_fix(model, req)
    fix_prompt = build_fix_prompt(req)
    @display.timestamped_puts "Retrying #{model} with fix...".blue
    @display.timestamped_puts ''

    success, _output = @agent_executor.run(model, fix_prompt)
    return [false, nil] unless success

    run_verification(model, req)
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
    req = @request_reader.read
    @request_reader.validate(req)
    @display.display_start_message(req)

    MODELS.each_with_index do |model, idx|
      @display.display_attempt_header(model, idx, MODELS.size)

      success, output = @agent_executor.run(model, req)
      unless success
        @display.display_agent_failure(output)
        next
      end

      result = process_model_attempt(model, req)
      return if result == :success
    end

    @display.display_all_attempts_failed
    @display.display_total_runtime(@start_time)
    @display.display_git_status
    exit 1
  end

  private

  def process_model_attempt(model, req)
    verified, desc = @verification_handler.run_verification(model, req)
    @display.timestamped_puts ''

    return handle_success(desc) if verified

    @display.display_verification_result(false, desc)
    @display.timestamped_puts ''

    verified, fix_desc = @verification_handler.retry_with_fix(model, req)
    @display.timestamped_puts ''

    return handle_success(fix_desc, 'after retry') if verified

    @display.display_verification_result(false, fix_desc, 'after retry')
    @display.timestamped_puts ''
    :continue
  end

  def handle_success(desc, context = '')
    @display.display_verification_result(true, desc, context)
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
