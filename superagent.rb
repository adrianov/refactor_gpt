#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/completion_notifier"
require "colorize"
require "shellwords"
require "reline"

CompletionNotifier.setup_exit_hook

$start_time = nil

def timestamped_puts(*args)
  args.each do |arg|
    time_str = Time.now.strftime("%Y-%m-%d %H:%M:%S")
    puts "[#{time_str}] #{arg}"
  end
end

# Configuration: Models to try in sequence
MODELS = [
  "auto",
  "gemini-3-flash",
  "claude-4.5-sonnet",
  "claude-4.5-opus"
].freeze

def get_user_request_from_argv
  ARGV.join(" ") unless ARGV.empty?
end

def get_user_request_from_stdin
  $stdin.read.strip unless $stdin.tty?
end

def read_interactive_request
  timestamped_puts "Enter your request:".cyan
  timestamped_puts "(Press Enter twice or Ctrl+D to submit)"
  timestamped_puts ""

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
  line = Reline.readline(lines.empty? ? "> " : "  ", true)
  return nil if line.nil?

  line = line.strip
  return :done if line.empty? && !lines.empty?
  return :continue if line.empty?

  line
end

def get_user_request
  get_user_request_from_argv || get_user_request_from_stdin || read_interactive_request
end

def run_agent_command(model, prompt)
  escaped_prompt = Shellwords.escape(prompt)
  cmd = "agent --print --model #{Shellwords.escape(model)} #{escaped_prompt}"
  timestamped_puts "Running: agent --print --model #{model} '#{prompt[0..50]}#{"..." if prompt.length > 50}'".green
  output = `#{cmd} 2>&1`
  output.each_line do |line|
    timestamped_puts line.chomp
  end
  [ $?.success?, output ]
end


def build_verification_prompt(user_request)
  <<~HEREDOC
    User request: #{user_request}

    Verify that the changes fully solve the user's request and introduce no new bugs or regressions.

    You may use any verification method you find appropriate, such as:
    - Reviewing git diff (run `git diff` to see changes)
    - Running tests or linting tools
    - Checking file contents
    - Any other verification approach you deem suitable

    After verification, respond with:
    - "YES: [short description of what was verified]" if the changes fully solve the request with no issues
    - "NO: [short description of what is wrong]" if there are issues

    Always include a brief description. Keep it specific and concise.
  HEREDOC
end

def build_fix_prompt(user_request)
  <<~HEREDOC
    Original user request: #{user_request}

    The previous attempt did not fully solve the request or introduced issues. Please fix the implementation.

    Review the current state of the codebase, identify what's missing or incorrect, and make the necessary corrections to:
    1. Fully solve the user's request
    2. Ensure no new bugs or regressions are introduced

    You may use git diff, file inspection, or any other method to understand the current state before applying fixes.
  HEREDOC
end

def parse_verification_response(response)
  return [false, nil] unless response

  normalized = response.strip
  return [false, nil] if normalized.empty?

  upcased = normalized.upcase
  yes_match = normalized.match(/\bYES\s*:?\s*(.+)/i)
  no_match = normalized.match(/\bNO\s*:?\s*(.+)/i)
  yes_index = upcased.index(/\bYES\b/)
  no_index = upcased.index(/\bNO\b/)

  if no_match && (!yes_index || (no_index && no_index < yes_index))
    description = no_match[1].strip
    return [false, description]
  end

  if yes_match && (!no_index || (yes_index && yes_index < no_index))
    description = yes_match[1].strip
    return [true, description]
  end

  # Fallback: if we see YES/NO without description, still parse it
  return [true, "Verification passed"] if yes_index && (!no_index || yes_index < no_index)
  return [false, "Verification failed"] if no_index

  [false, nil]
end

def run_verification(model, user_request)
  verification_prompt = build_verification_prompt(user_request)
  timestamped_puts "Verifying solution with #{model}...".blue
  timestamped_puts "Running: agent --print --model #{model} [verification prompt]".green

  output = `agent --print --model #{Shellwords.escape(model)} #{Shellwords.escape(verification_prompt)} 2>&1`
  output.each_line do |line|
    timestamped_puts line.chomp
  end
  success = $?.success?

  return [false, nil, output] unless success

  verified, description = parse_verification_response(output.strip)
  [verified, description, output]
end

def validate_user_request(user_request)
  return true if user_request && !user_request.strip.empty?

  timestamped_puts "No request provided. Exiting.".yellow
  exit 1
end

def display_start_message(user_request)
  timestamped_puts "\nStarting superagent with request:".cyan
  timestamped_puts "#{user_request}\n".yellow
  timestamped_puts ""
end

def display_attempt_header(model, index)
  attempt = index + 1
  timestamped_puts "--- Attempt #{attempt}/#{MODELS.size}: Using #{model} ---".blue
  timestamped_puts ""
end

def attempt_retry_with_fix(model, user_request)
  fix_prompt = build_fix_prompt(user_request)
  timestamped_puts "Retrying with #{model} using fix instruction...".blue
  timestamped_puts ""

  success, output = run_agent_command(model, fix_prompt)
  return [false, nil, output] unless success

  run_verification(model, user_request)
end

def process_model_attempt(model, user_request)
  verified, description, verification_output = run_verification(model, user_request)
  timestamped_puts ""

  if verified
    if description && !description.empty?
      timestamped_puts "✓ Verification passed: #{description}".green
    else
      timestamped_puts "✓ Verification passed! Changes solve the request with no new bugs.".green
    end
    display_total_runtime
    exit 0
  end

  if description && !description.empty?
    timestamped_puts "✗ Verification failed: #{description}".yellow
  else
    timestamped_puts "✗ Verification failed. Retrying once with fix instruction...".yellow
  end
  timestamped_puts ""

  verified, fix_description, fix_output = attempt_retry_with_fix(model, user_request)
  timestamped_puts ""

  if verified
    if fix_description && !fix_description.empty?
      timestamped_puts "✓ Verification passed after retry: #{fix_description}".green
    else
      timestamped_puts "✓ Verification passed after retry! Changes solve the request with no new bugs.".green
    end
    display_total_runtime
    exit 0
  end

  if fix_description && !fix_description.empty?
    timestamped_puts "✗ Verification failed after retry: #{fix_description}".yellow
  else
    timestamped_puts "✗ Verification failed after retry. Trying next model...".yellow
  end
  timestamped_puts ""
  
  [false, fix_output || verification_output]
end

def handle_agent_failure
  timestamped_puts "Agent command failed. Continuing to next model...".yellow
  timestamped_puts ""
end

def format_duration(seconds)
  minutes = (seconds / 60).to_i
  remaining_seconds = (seconds % 60).to_i
  "#{minutes}m #{remaining_seconds}s"
end

def display_total_runtime
  return unless $start_time

  elapsed_time = Time.now - $start_time
  timestamped_puts "Total run time: #{format_duration(elapsed_time)}".cyan
end

def main
  $start_time = Time.now
  user_request = get_user_request
  validate_user_request(user_request)
  display_start_message(user_request)

  MODELS.each_with_index do |model, index|
    display_attempt_header(model, index)

    success, _output = run_agent_command(model, user_request)
    unless success
      handle_agent_failure
      next
    end

    process_model_attempt(model, user_request)
  end

  timestamped_puts "All attempts completed. Verification did not pass with any model.".red
  display_total_runtime
  exit 1
end

if __FILE__ == $PROGRAM_NAME
  CompletionNotifier.wrap_main do
    main
  end
end
