#!/usr/bin/env ruby
# frozen_string_literal: true

require "colorize"
require "shellwords"
require "reline"

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
  puts "Enter your request:".cyan
  puts "(Press Enter twice or Ctrl+D to submit)"
  puts ""

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
  puts "Running: agent --print --model #{model} '#{prompt[0..50]}#{"..." if prompt.length > 50}'".green
  system(cmd)
  $?.success?
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

    After verification, respond with ONLY "YES" or "NO" - no other text, no explanation, no additional words.
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
  return false unless response

  normalized = response.strip.upcase
  return false if normalized.empty?

  yes_index = normalized.index(/\bYES\b/)
  no_index = normalized.index(/\bNO\b/)

  return false if no_index && (!yes_index || no_index < yes_index)
  return true if yes_index

  false
end

def run_verification(model, user_request)
  verification_prompt = build_verification_prompt(user_request)
  puts "Verifying solution with #{model}...".blue
  puts "Running: agent --print --model #{model} [verification prompt]".green

  output = `agent --print --model #{Shellwords.escape(model)} #{Shellwords.escape(verification_prompt)} 2>&1`
  success = $?.success?

  return false unless success

  parse_verification_response(output.strip)
end

def validate_user_request(user_request)
  return true if user_request && !user_request.strip.empty?

  puts "No request provided. Exiting.".yellow
  exit 1
end

def display_start_message(user_request)
  puts "\nStarting superagent with request:".cyan
  puts "#{user_request}\n".yellow
  puts ""
end

def display_attempt_header(model, index)
  attempt = index + 1
  puts "--- Attempt #{attempt}/#{MODELS.size}: Using #{model} ---".blue
  puts ""
end

def attempt_retry_with_fix(model, user_request)
  fix_prompt = build_fix_prompt(user_request)
  puts "Retrying with #{model} using fix instruction...".blue
  puts ""

  return false unless run_agent_command(model, fix_prompt)

  run_verification(model, user_request)
end

def process_model_attempt(model, user_request)
  verified = run_verification(model, user_request)
  puts ""

  if verified
    puts "✓ Verification passed! Changes solve the request with no new bugs.".green
    exit 0
  end

  puts "✗ Verification failed. Retrying once with fix instruction...".yellow
  puts ""

  verified = attempt_retry_with_fix(model, user_request)
  puts ""

  if verified
    puts "✓ Verification passed after retry! Changes solve the request with no new bugs.".green
    exit 0
  end

  puts "✗ Verification failed after retry. Trying next model...".yellow
  puts ""
  false
end

def handle_agent_failure
  puts "Agent command failed. Continuing to next model...".yellow
  puts ""
end

def main
  user_request = get_user_request
  validate_user_request(user_request)
  display_start_message(user_request)

  MODELS.each_with_index do |model, index|
    display_attempt_header(model, index)

    unless run_agent_command(model, user_request)
      handle_agent_failure
      next
    end

    process_model_attempt(model, user_request)
  end

  puts "All attempts completed. Verification did not pass with any model.".red
  exit 1
end

main if __FILE__ == $PROGRAM_NAME
