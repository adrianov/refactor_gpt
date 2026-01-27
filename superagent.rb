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
require 'shellwords'
require_relative "lib/agents_file_handler"

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
      timestamped_puts "#{prefix}#{suffix}:".send(verified ? :green : :yellow)
      desc.each_line { |line| timestamped_puts "  #{line.chomp}" }
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
      output.each_line { |line| timestamped_puts "  #{line.chomp}" }
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
  TEST_RUNNER_CHECK_INTERVAL = 2

  def initialize(display)
    @display = display
  end

  def test_runner_running?(pid = nil)
    return false unless RbConfig::CONFIG['host_os'] =~ /linux|darwin|bsd/

    # If pid is provided, we check for descendants of that pid
    # Otherwise we check for any test runner process in the system
    TEST_RUNNERS.any? do |runner|
      if pid
        # Find all descendants of the given PID and check if any match the runner name
        # We use 'ps -eo ppid,comm' to get parent-child relationships
        # and search for the runner in the descendants
        descendants = get_all_descendants(pid)
        descendants.any? { |d_pid| process_matches_runner?(d_pid, runner) }
      else
        system_runner_running?(runner)
      end
    end
  end

  def system_runner_running?(runner)
    # Check for exact process name match (avoids false positives from pgrep -f)
    return true if system("pgrep -x #{runner} > #{File::NULL} 2>&1")

    # Check for runners invoked via interpreters, but only if runner appears as executable argument
    # This avoids matching processes that just mention the runner in file paths or grep patterns
    output = `ps ax -o comm,args 2>/dev/null`
    return false if output.empty?

    output.each_line do |line|
      next if line.strip.empty?

      parts = line.split(nil, 2)
      next if parts.length < 2

      comm = parts[0]
      args = parts[1] || ''

      # Only check interpreter processes
      next unless %w[ruby node python].include?(comm)

      # Runner must appear as an executable argument (after bundle exec, or as direct arg)
      # Pattern ensures runner is a command, not part of a file path
      next unless args.match?(/\b(?:bundle\s+exec\s+)?#{runner}(?:\s|$)/)

      # Exclude processes that are searching/editing (grep, editors, etc.)
      next if args.match?(/\b(?:grep|find|vim|nano|emacs|less|more|cat|head|tail|ag|rg)\s/)

      return true
    end
    false
  end

  def get_all_descendants(parent_pid)
    descendants = []
    # Get all processes with their PPIDs
    output = `ps -eo ppid,pid 2>/dev/null`
    return [] if output.empty?

    # Build a parent-to-children map
    p_to_c = Hash.new { |h, k| h[k] = [] }
    output.each_line.map(&:split).each do |ppid, pid|
      next unless ppid && pid

      p_to_c[ppid.to_i] << pid.to_i
    end

    # BFS to find all descendants
    queue = [parent_pid.to_i]
    while queue.any?
      curr = queue.shift
      children = p_to_c[curr]
      if children
        descendants.concat(children)
        queue.concat(children)
      end
    end
    descendants
  end

  def process_matches_runner?(pid, runner)
    # Check if the command line of the process contains the runner name
    cmdline = `ps -p #{pid} -o args= 2>/dev/null`.strip
    cmdline.include?(runner)
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

  def run_with_timeout_monitoring(model, wrapped)
    # Check if a test runner is already running in the system before starting the agent
    if test_runner_running?
      @display.timestamped_puts '⚠️  Test runner already running in system, no timeout applied'.yellow
      return Open3.capture3('agent', '--print', '--model', model, wrapped)
    end

    test_runner_detected = false
    execution_complete = false
    process_pid = nil
    timeout_disabled = false

    monitor_thread = Thread.new do
      loop do
        sleep TEST_RUNNER_CHECK_INTERVAL
        break if execution_complete

        if process_pid && test_runner_running?(process_pid)
          unless test_runner_detected
            test_runner_detected = true
            timeout_disabled = true
            @display.timestamped_puts '⚠️  Test runner detected (child of agent), disabling timeout'.yellow
          end
        end
      end
    end

    timeout_thread = Thread.new do
      elapsed = 0
      while elapsed < EXECUTION_TIMEOUT && !execution_complete
        sleep TEST_RUNNER_CHECK_INTERVAL
        elapsed += TEST_RUNNER_CHECK_INTERVAL
        next if timeout_disabled || (process_pid && test_runner_running?(process_pid))

        if elapsed >= EXECUTION_TIMEOUT && !execution_complete
          @display.timestamped_puts "❌ Agent timed out after #{EXECUTION_TIMEOUT}s".red
          Process.kill('TERM', process_pid) if process_pid
          break
        end
      end
    end

    begin
      Open3.popen2e('agent', '--print', '--model', model, wrapped) do |_stdin, stdout_stderr, wait_thr|
        process_pid = wait_thr.pid
        output = stdout_stderr.read
        begin
          status = wait_thr.value
        rescue StandardError
          status = Struct.new(:success?).new(false)
        end
        execution_complete = true
        [output || '', '', status]
      end
    rescue Errno::ESRCH, Errno::ECHILD
      execution_complete = true
      [nil, nil, Struct.new(:success?).new(false)]
    ensure
      execution_complete = true
      monitor_thread&.kill
      timeout_thread&.kill
    end
  end

  def run(model, p, max_retries: 3, base_delay: 1)
    wrapped = wrap_prompt(p)
    retries = 0

    loop do
      @display.timestamped_puts "Running: agent --model #{model} '#{p[0..50].gsub("\n", " ")}...'"
      stdout, stderr, status = nil
      begin
        stdout, stderr, status = run_with_timeout_monitoring(model, wrapped)
        if status.nil? || !status.success?
          return [false, "Timeout after #{EXECUTION_TIMEOUT}s"] if stdout.nil?
        end
      rescue StandardError => e
        @display.timestamped_puts "❌ Agent execution error: #{e.message}".red
        return [false, "Execution error: #{e.message}"]
      end

      output = (stdout || '') + (stderr || '')
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

  def run_plan_mode(model, p)
    wrapped = wrap_prompt(p)
    @display.timestamped_puts "Running: agent --plan --model #{model} '#{p[0..50].gsub("\n", " ")}...'"
    
    stdout, stderr, status = Open3.capture3('agent', '--plan', '--print', '--model', model, wrapped)
    output = (stdout || '') + (stderr || '')
    output.each_line { |line| @display.timestamped_puts line.chomp }
    
    [status.success?, output]
  rescue StandardError => e
    @display.timestamped_puts "❌ Agent execution error: #{e.message}".red
    [false, "Execution error: #{e.message}"]
  end
end

# Handles verification prompts and response parsing
class VerificationHandler
  include AgentsFileHandler

  def initialize(display, agent_executor)
    @display = display
    @agent_executor = agent_executor
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
    m = n.match(/\bNO\s*:?\s*([\s\S]+)/i)
    [false, m ? m[1].strip : 'Failed']
  end

  def parse_yes_res(n)
    m = n.match(/\bYES\s*:?\s*([\s\S]+)/i)
    [true, m ? m[1].strip : 'Passed']
  end

  def collect_git_status
    output = `git status --porcelain --branch 2>&1`
    unless $?.success?
      @display.timestamped_puts 'Warning: Failed to get git status'.yellow
      return ''
    end
    output
  end

  def prepare_untracked_files
    all_untracked = `git ls-files --others --exclude-standard 2>&1`.split("\n")
    additional_exclusions = [
      '*.log', '*.tmp', '*.temp', '*.bak', '*.swp', '*.swo',
      '*.pyc', '*.pyo', '*.class', '*.jar', '*.war', '*.ear',
      '*.zip', '*.tar.gz', '*.tgz', '*.rar', '*.exe', '*.dll',
      '*.so', '*.dylib', '*.bin', '*.dat', '*.orig', '*.rej',
      '.DS_Store', 'Thumbs.db'
    ]
    files_to_add = all_untracked.reject do |file|
      additional_exclusions.any? { |pattern| File.fnmatch(pattern, File.basename(file)) }
    end

    return if files_to_add.empty?

    add_cmd = ['git', 'add', '-N', *files_to_add].map { |p| Shellwords.escape(p) }.join(' ')
    system("#{add_cmd} 2>/dev/null")
  end

  def collect_git_diff
    output = `git diff -U500 2>&1`
    unless $?.success?
      @display.timestamped_puts 'Warning: Failed to get git diff'.yellow
      return ''
    end
    output
  end

  def build_verification_system_instruction
    agents_content = load_agents_file
    has_agents = !agents_content.empty?

    instruction_parts = [
      <<~HEREDOC
        You are a tool that verifies whether code changes fully implement a requested feature.

        IMPORTANT: This agent is running in non-interactive mode. Do not ask questions, request user input, or wait for confirmation. Work autonomously using available information and make reasonable decisions based on context. Execute tasks directly without seeking clarification.
      HEREDOC
    ]

    instruction_parts << "- Ruby development guidelines from AGENTS.md\n" if has_agents

    instruction_parts << <<~HEREDOC

      Task:
      Verify that the changes fully solve the user's request and introduce no new bugs or regressions.

      You may use any verification method you find appropriate, such as:
      - Reviewing git diff (run `git diff` to see changes)
      - Running tests or linting tools
      - Checking file contents
      - Any other verification approach you deem suitable

      After verification, respond with:
>>>>>>> a2db7d8 (refactor: use agent ask mode for primary verification with verify_gpt fallback)
      - "YES: [short description of what was verified]" if the changes fully solve the request with no issues
      - "NO: [short description of what is wrong]" if there are issues

      CRITICAL: Your response MUST start with either "YES" or "NO" as the first word. This is required for automated parsing.
      Always include a brief description after the YES/NO. Keep it specific and concise.
    HEREDOC

    if has_agents
      instruction_parts << <<~HEREDOC

        AGENTS.md content (development guidelines to consider):
        #{agents_content}
      HEREDOC
    end

    instruction_parts.join
  end

  def build_verification_user_content(user_request, status_output, diff_output)
    content_parts = [
      "User request: #{user_request}\n\n",
      "Here is the git status:\n#{status_output.strip}\n\n"
    ]

    unless diff_output.strip.empty?
      content_parts << "Here is the git diff for all changes:\n#{diff_output.strip}\n"
    end

    content_parts.join("\n")
  end

  def build_verification_prompt(req)
    status_output = collect_git_status
    prepare_untracked_files
    diff_output = collect_git_diff

    system_instruction = build_verification_system_instruction
    user_content = build_verification_user_content(req, status_output, diff_output)

    <<~HEREDOC
      #{system_instruction}

      ---

      #{user_content}
    HEREDOC
  end

  def run_verification(model, req)
    @display.timestamped_puts 'Verifying...'.blue

    verification_prompt = build_verification_prompt(req)
    @display.timestamped_puts "Running: agent --mode ask --model #{model} '[verification prompt]'"

    stdout, stderr, status = Open3.capture3('agent', '--mode', 'ask', '--model', model, '--print', verification_prompt)
    output = stdout + stderr
    output.each_line { |line| @display.timestamped_puts line.chomp }

    if status.success?
      verified, desc = parse_res(stdout.strip)
      return [verified, desc || 'Failed'] unless desc.nil?
    end

    @display.timestamped_puts 'Primary verification failed, using verify_gpt.rb as fallback...'.yellow
    run_verification_fallback(req)
  end

  def run_verification_fallback(req)
    verify_script = File.join(__dir__, 'verify_gpt.rb')
    return [false, 'verify_gpt.rb not found'] unless File.exist?(verify_script)

    @display.timestamped_puts "Running: #{verify_script} '#{req[0..50]}...'"

    stdout, stderr, status = Open3.capture3('ruby', verify_script, req)
    output = stdout + stderr
    output.each_line { |line| @display.timestamped_puts line.chomp }

    return [false, 'Verification fallback command failed'] unless status.success?

    verified, desc = parse_res(stdout.strip)
    [verified, desc || 'Failed']
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
