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

require 'colorize'
require 'reline'
require 'open3'
require 'timeout'
require 'rbconfig'
require 'shellwords'
require 'json'
require_relative "lib/agents_file_handler"
require_relative "lib/diff_processor"
require_relative "lib/completion_notifier"
require_relative "lib/instance_lock"

# Handles all output formatting and display operations
class Display
  def puts(*args)
    @at_start_of_line = true
    return super(*args) if args.empty? || args.first.to_s.strip.empty?

    timestamp = Time.now.strftime("[%H:%M:%S] ")
    if args.first.is_a?(String)
      args[0] = format_with_timestamp(args[0], timestamp)
    else
      super(timestamp)
    end
    super(*args)
    $stdout.flush
  end

  def initialize
    @text_buffer = ''
    @at_start_of_line = true
  end

  def check_late_night_reminder
    now = Time.now
    hour = now.hour
    minute = now.min

    # Check if time is between 23:30 and 6:00
    is_late_night = (hour == 23 && minute >= 30) || (hour >= 0 && hour < 6)
    return unless is_late_night

    messages = [
      "🌙 It's getting late! Your code will still be here tomorrow, and you'll tackle it with fresh eyes.",
      "⏰ Late night coding session! Remember, a well-rested mind writes better code. Tomorrow will be productive!",
      "🌆 The clock says it's time to wind down. Your future self will thank you for getting some rest.",
      "💤 It's past bedtime! Your code isn't going anywhere, but your energy is. Rest up for an amazing day!",
      "🌃 Late night warrior! Dedication is admirable, but remember that tomorrow you'll be even more productive.",
      "⭐ Burning the midnight oil? That's dedication! But even the best developers need sleep. Rest up!",
      "🌙 Late night coding is impressive, but so is a good night's sleep. Your code will be waiting for you."
    ]

    message = messages.sample
    $stdout.puts ''
    puts message.yellow
    $stdout.puts ''
    exit 0
  end

  def print_word(text)
    return if text.nil? || text.empty?

    @text_buffer ||= ''
    @at_start_of_line ||= true
    @has_printed_content ||= false

    # Add text to buffer
    @text_buffer += text

    # Process complete lines (ending with newline) - these get timestamps
    process_complete_lines

    # If buffer is getting large and no newlines, print it
    # Add timestamp only if at start of line
    if @text_buffer.length > 200 && !@text_buffer.include?("\n")
      ensure_timestamp if @at_start_of_line
      $stdout.print @text_buffer
      @text_buffer = ''
      @at_start_of_line = false
      @has_printed_content = true
      $stdout.flush
    end
  end

  def flush_word_buffer
    return if @text_buffer.nil? || @text_buffer.empty?

    @text_buffer ||= ''
    @at_start_of_line ||= true

    # Collapse multiple trailing newlines to a single newline to avoid extra blank lines
    @text_buffer = @text_buffer.sub(/\n{2,}\z/, "\n")

    # Process any remaining complete lines (these will get timestamps and newlines)
    process_complete_lines

    # Print any remaining buffered content
    # Only add timestamp if we're at start of line (after processing newlines above)
    unless @text_buffer.strip.empty?
      ensure_timestamp if @at_start_of_line
      $stdout.print @text_buffer
      # Ensure newline at end if not already present
      $stdout.puts '' unless @text_buffer.end_with?("\n")
      @text_buffer = ''
      @at_start_of_line = true
      @has_printed_content = true
      $stdout.flush
    end
  end

  def display_git_status
    return unless git_repo?

    status = `git status --short 2>&1`.strip
    return if status.empty?

    puts 'Git status:'.cyan
    status.each_line { |line| $stdout.puts "  #{line.chomp}" }
    $stdout.puts ''
    display_git_diff
  end

  def display_git_diff
    return unless git_repo?

    system("git diff")
    $stdout.puts ''
  end

  def display_start_message(req)
    puts "\nSuperagent:".cyan
    puts req.yellow
    $stdout.puts ''
    display_git_status
  end

  def display_attempt_header(model, idx, total)
    puts "--- Attempt #{idx + 1}/#{total}: #{model} ---".blue
    $stdout.puts ''
  end

  def display_verification_result(verified, desc, context = '')
    prefix = verified ? '✓ Passed' : '✗ Failed'
    suffix = context.empty? ? '' : " #{context}"

    if desc && !desc.empty?
      puts "#{prefix}#{suffix}:".send(verified ? :green : :yellow)
      desc.each_line { |line| $stdout.puts "  #{line.chomp}" }
    elsif verified
      puts "#{prefix}#{suffix}! Success.".send(:green)
    else
      puts "#{prefix}#{suffix}! #{context.empty? ? 'Retrying...' : 'Next...'}".send(:yellow)
    end
  end

  def display_total_runtime(start_time)
    return unless start_time

    elapsed = Time.now - start_time
    puts "Run time: #{format_duration(elapsed)}".cyan
  end

  def display_agent_failure(output = nil)
    puts 'Agent failed. Next...'.yellow
    if output && !output.strip.empty?
      $stdout.puts ''
      $stdout.puts 'Agent output:'.yellow
      output.each_line { |line| $stdout.puts "  #{line.chomp}" }
    end
    $stdout.puts ''
  end

  def display_all_attempts_failed
    puts 'All attempts failed.'.red
  end

  def git_repo?
    system("git rev-parse --is-inside-work-tree > #{File::NULL} 2>&1")
  end

  def update_git_status
    return unless git_repo?

    puts 'Updating git status...'.cyan
    system("git fetch > #{File::NULL} 2>&1")
    status_output = `git status 2>&1`
    if $?.success?
      status_output.strip.each_line { |line| $stdout.puts line.chomp }
    else
      puts 'Warning: Failed to get git status'.yellow
    end
    $stdout.puts ''
  end

  def suggest_git_init
    return if git_repo?

    $stdout.puts ''
    puts '💡 Suggestion: Initialize a git repository for better tracking and verification.'.yellow
    $stdout.puts ''
    puts 'Advantages:'.cyan
    $stdout.puts '  • Automatic change tracking - see exactly what was modified'
    $stdout.puts '  • Faster verification - uses git diff instead of reading all files'
    $stdout.puts '  • Better context for AI - only changed code is analyzed'
    $stdout.puts '  • Easy rollback - revert changes if needed'
    $stdout.puts '  • Version history - track your code evolution'
    $stdout.puts ''

    return unless $stdin.tty?

    puts 'Initialize git repository? (y/N)'.white
    answer = $stdin.gets.to_s.chomp.downcase

    if answer == 'y'
      puts 'Running: git init'.green
      success = system('git init')
      if success
        puts 'Git repository initialized successfully.'.green
      else
        puts 'Failed to initialize git repository.'.yellow
      end
      $stdout.puts ''
    else
      puts 'Skipping git initialization.'.yellow
      $stdout.puts ''
    end
  end

  private

  def format_with_timestamp(text, timestamp)
    # Handle colorized strings which might have escape codes at the beginning
    if text.start_with?("\e[")
      # Find the first 'm' which ends the escape sequence
      m_index = text.index('m')
      if m_index
        # Insert timestamp after the first color escape sequence
        return text[0..m_index] + timestamp + text[m_index + 1..-1]
      end
    end
    "#{timestamp}#{text}"
  end

  def process_complete_lines
    return if @text_buffer.empty?

    # Process all complete lines (ending with newline)
    while (newline_idx = @text_buffer.index("\n"))
      # Get the complete line including the newline
      line_with_newline = @text_buffer[0..newline_idx]
      @text_buffer = @text_buffer[(newline_idx + 1)..-1] || ''

      # Print the line content (without the newline, we'll add it separately)
      line_content = line_with_newline.chomp
      unless line_content.empty?
        ensure_timestamp
        $stdout.print line_content
      end

      # Print the newline and reset state for next line
      $stdout.puts ''
      @at_start_of_line = true
      @has_printed_content = true
      $stdout.flush
    end
  end

  def ensure_timestamp
    return unless @at_start_of_line

    timestamp = Time.now.strftime("[%H:%M:%S] ")
    $stdout.print timestamp
    @at_start_of_line = false
  end

  def format_duration(sec)
    "#{(sec / 60).to_i}m #{(sec % 60).to_i}s"
  end
end

# Handles reading user requests from various sources
class RequestReader
  def initialize(display)
    @display = display
    @plan_mode = false
  end

  attr_reader :plan_mode

  def read_from_argv
    return nil if ARGV.empty?

    args = ARGV.dup
    if args.include?('--plan')
      @plan_mode = true
      args.delete('--plan')
    end
    args.delete('--print')

    args.join(' ') unless args.empty?
  end

  def read_from_stdin
    $stdin.read.strip unless $stdin.tty?
  end

  def read_interactive
    puts 'Enter request:'.cyan
    puts '(Press Enter twice, Ctrl+D, or Ctrl+C to submit/exit)'
    $stdout.puts ''

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
  rescue Interrupt
    $stdout.puts ''
    puts 'Interrupted. Exiting.'.yellow
    exit 0
  end

  def read
    read_from_argv || read_from_stdin || read_interactive
  end

  def validate(req)
    return true if req && !req.strip.empty?

    puts 'No request provided. Exiting.'.yellow
    exit 1
  end
end

# Handles agent command execution with retry logic
class AgentExecutor
  EXECUTION_TIMEOUT = 60
  MAX_EXECUTION_TIMEOUT = 600
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
    p
  end

  def parse_json_stream_line(line)
    return [nil, nil] if line.nil? || line.strip.empty? || line.include?('=>')
    return [nil, nil] if (line.include?('"role"') || line.include?("'role'") || line.include?(':role')) &&
                        (line.include?('"user"') || line.include?("'user'") || line.include?(':user'))

    json_obj = JSON.parse(line.strip)
    type = json_obj['type']
    text = extract_text_from_json(json_obj)

    text = text.to_s unless text.nil?
    text = nil if text&.empty?
    [type, text]
  rescue JSON::ParserError
    [nil, nil]
  end

  def extract_text_from_json(json_obj)
    case json_obj['type']
    when 'assistant'
      content = json_obj.dig('message', 'content')
      if content.is_a?(Array)
        text_content = content.find { |c| c['type'] == 'text' }
        text_content ? text_content['text'] : nil
      elsif content.is_a?(String)
        content
      else
        json_obj.dig('message', 'text') || json_obj['text']
      end
    when 'result'
      json_obj['result']
    when 'step', 'tool_call', 'tool_result'
      json_obj['step'] || json_obj['text'] || json_obj['content'] || json_obj['result']
    else
      json_obj['text'] || json_obj['content'] || json_obj['result'] || json_obj['message']
    end
  end

  def build_and_display_command(*args, verification_mode: false)
    cmd = ['agent', '--print', '--stream-partial-output', '--output-format', 'stream-json']
    if verification_mode
      cmd << '--mode' << 'ask'
    else
      cmd << '--force'
    end
    cmd.concat(args)
    display_cmd = cmd.map do |arg|
      if arg.length > 50 || arg.include?("\n")
        "'#{arg[0..50].gsub("\n", " ")}...'"
      else
        arg
      end
    end.join(' ')
    puts "Running: #{display_cmd}"
    cmd
  end

  def retryable_network_error?(output)
    return false if output.nil? || output.empty?

    output.include?('CANCEL') || output.include?('canceled') ||
      output.include?('stream closed') || output.include?('0x8') ||
      output.include?('http/2 stream closed') || output.include?('Connection stalled')
  end

  def run_with_timeout_monitoring(model, wrapped, verification_mode: false)
    # Check if a test runner is already running in the system before starting the agent
    if test_runner_running?
      puts '⚠️  Test runner already running in system, no timeout applied'.yellow
      return run_without_timeout(model, wrapped, verification_mode: verification_mode)
    end

    test_runner_detected = false
    execution_complete = false
    process_pid = nil
    timeout_disabled = false
    timed_out = false
    last_chunk_time = nil
    execution_start_time = nil

    monitor_thread = Thread.new do
      loop do
        sleep TEST_RUNNER_CHECK_INTERVAL
        break if execution_complete

        if process_pid && test_runner_running?(process_pid)
          unless test_runner_detected
            test_runner_detected = true
            timeout_disabled = true
            puts '⚠️  Test runner detected (child of agent), disabling timeout'.yellow
          end
        end
      end
    end

    timeout_thread = Thread.new do
      while !execution_complete
        sleep TEST_RUNNER_CHECK_INTERVAL
        next if timeout_disabled || (process_pid && test_runner_running?(process_pid))

        if execution_start_time
          total_execution_time = Time.now - execution_start_time
          if total_execution_time >= MAX_EXECUTION_TIMEOUT && !execution_complete
            timed_out = true
            puts "❌ Agent timed out after #{MAX_EXECUTION_TIMEOUT}s maximum execution time".red
            Process.kill('TERM', process_pid) if process_pid
            sleep 2
            Process.kill('KILL', process_pid) if process_pid && !execution_complete
            break
          end
        end

        next if last_chunk_time.nil?

        time_since_last_chunk = Time.now - last_chunk_time
        if time_since_last_chunk >= EXECUTION_TIMEOUT && !execution_complete
          timed_out = true
          puts "❌ Agent timed out after #{EXECUTION_TIMEOUT}s without receiving data".red
          Process.kill('TERM', process_pid) if process_pid
          sleep 2
          Process.kill('KILL', process_pid) if process_pid && !execution_complete
          break
        end
      end
    end

    begin
      cmd = build_and_display_command('--model', model, wrapped, verification_mode: verification_mode)
      Open3.popen2e(*cmd) do |stdin, stdout_stderr, wait_thr|
        process_pid = wait_thr.pid
        execution_start_time = Time.now
        last_chunk_time = Time.now
        raw_output = ''
        final_result = ''
        stdin.close
        line_buffer = ''

        loop do
          break if timed_out

          ready = IO.select([stdout_stderr], nil, nil, 0.5)
          if ready
            begin
              chunk = stdout_stderr.readpartial(4096)
              last_chunk_time = Time.now
              raw_output += chunk
              line_buffer += chunk

              while (newline_idx = line_buffer.index("\n"))
                line = line_buffer[0..newline_idx]
                line_buffer = line_buffer[(newline_idx + 1)..-1] || ''

                type, text = parse_json_stream_line(line.strip)
                if text && !text.empty?
                  if type == 'result'
                    final_result = text
                  else
                    @display.print_word(text)
                  end
                end
              end
            rescue EOFError
              break
            rescue IO::WaitReadable
              next
            end
          elsif !wait_thr.alive?
            begin
              remaining = stdout_stderr.read
              if remaining
                last_chunk_time = Time.now
                raw_output += remaining
                line_buffer += remaining

                # Process remaining complete lines the same way as in main loop
                while (newline_idx = line_buffer.index("\n"))
                  line = line_buffer[0..newline_idx]
                  line_buffer = line_buffer[(newline_idx + 1)..-1] || ''

                  type, text = parse_json_stream_line(line.strip)
                  if text && !text.empty?
                    if type == 'result'
                      final_result = text
                    else
                      @display.print_word(text)
                    end
                  end
                end
              end
            rescue EOFError
              # Stream closed, no more data
            rescue IOError => e
              # Error reading remaining data, log and continue
              puts "Warning: Error reading remaining output: #{e.message}".yellow
            end
            break
          end
        end

        if timed_out
          stdout_stderr.close rescue nil
          final_result += "\n[Process terminated due to timeout]"
        end

        # Process any remaining incomplete line in line_buffer
        unless line_buffer.empty?
          type, text = parse_json_stream_line(line_buffer.strip)
          if text && !text.empty?
            if type == 'result'
              final_result = text
            else
              @display.print_word(text)
            end
          end
        end

        execution_complete = true

        # Flush any remaining buffered text
        @display.flush_word_buffer

        begin
          status = wait_thr.value
        rescue StandardError
          status = Struct.new(:success?).new(false)
        end

        if timed_out
          status = Struct.new(:success?).new(false)
        end

        output = final_result.empty? ? raw_output : final_result
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

  def run_without_timeout(model, wrapped, verification_mode: false)
    cmd = build_and_display_command('--model', model, wrapped, verification_mode: verification_mode)
    stdout, stderr, status = Open3.capture3(*cmd)
    raw_output = stdout + stderr
    final_result = ''

    raw_output.each_line do |line|
      type, text = parse_json_stream_line(line.strip)
      if text && !text.empty?
        if type == 'result'
          final_result = text
        else
          @display.print_word(text)
        end
      end
    end

    # Flush any remaining buffered text
    @display.flush_word_buffer

    output = final_result.empty? ? raw_output : final_result
    [output, '', status]
  end

  def run(model, p, max_retries: 3, base_delay: 1, verification_mode: false)
    wrapped = wrap_prompt(p)
    retries = 0

    loop do
      stdout, stderr, status = nil
      begin
        stdout, stderr, status = run_with_timeout_monitoring(model, wrapped, verification_mode: verification_mode)
        if status.nil? || !status.success?
          return [false, "Timeout after #{EXECUTION_TIMEOUT}s"] if stdout.nil?
        end
      rescue StandardError => e
        puts "❌ Agent execution error: #{e.message}".red
        return [false, "Execution error: #{e.message}"]
      end

      output = (stdout || '') + (stderr || '')
      # Output is already processed and displayed by run_with_timeout_monitoring
      return [status.success?, output] if status.success?

      if retryable_network_error?(output) && retries < max_retries
        retries += 1
        delay = base_delay * (2**(retries - 1))
        puts "⚠️  Network error, retrying in #{delay}s... (#{retries}/#{max_retries})".yellow
        sleep(delay)
        next
      end

      return [false, output]
    end
  end

  def run_plan_mode(model, p)
    wrapped = wrap_prompt(p)
    cmd = build_and_display_command('--plan', '--model', model, wrapped)
    
    stdout, stderr, status = Open3.capture3(*cmd)
    raw_output = (stdout || '') + (stderr || '')
    final_result = ''
    
    raw_output.each_line do |line|
      type, text = parse_json_stream_line(line.strip)
      if text && !text.empty?
        if type == 'result'
          final_result = text
        else
          @display.print_word(text)
        end
      end
    end
    
    # Flush any remaining buffered text
    @display.flush_word_buffer
    
    output = final_result.empty? ? raw_output : final_result
    [status.success?, output]
  rescue StandardError => e
    puts "❌ Agent execution error: #{e.message}".red
    [false, "Execution error: #{e.message}"]
  end
end

# Handles verification prompts and response parsing
class VerificationHandler
  include AgentsFileHandler

  MAX_CONTENT_SIZE_KB = 100

  def initialize(display, agent_executor)
    @display = display
    @agent_executor = agent_executor
    @diff_processor = DiffProcessor.new
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

    n = normalize_response(res)
    up = n.upcase

    # Prioritize NO if both are present and NO comes first
    yes_match = up.match(/\bYES\b/i)
    no_match = up.match(/\bNO\b/i)

    if no_match && (yes_match.nil? || no_match.begin(0) < yes_match.begin(0))
      parse_no_res(n)
    elsif yes_match
      parse_yes_res(n)
    else
      [false, res]
    end
  end

  def normalize_response(res)
    normalized = res.strip
    normalized = normalized.gsub(/\*\*(.*?)\*\*/, '\1')
    normalized = normalized.gsub(/\*(.*?)\*/, '\1')
    normalized = normalized.gsub(/__(.*?)__/, '\1')
    normalized = normalized.gsub(/_(.*?)_/, '\1')
    normalized.strip
  end

  def parse_no_res(n)
    m = n.match(/\bNO\b\s*:?\s*(.*)/i)
    description = m ? m[1].strip : ''
    [false, description.empty? ? 'Failed' : description]
  end

  def parse_yes_res(n)
    m = n.match(/\bYES\b\s*:?\s*(.*)/i)
    description = m ? m[1].strip : ''
    [true, description.empty? ? 'Passed' : description]
  end

  def git_repo?
    @display.git_repo?
  end

  def collect_git_status
    return '' unless git_repo?

    output = `git status --porcelain --branch 2>&1`
    unless $?.success?
      @display.timestamped_puts 'Warning: Failed to get git status'.yellow
      return ''
    end
    output
  end

  def prepare_untracked_files
    return unless git_repo?

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
    return '' unless git_repo?

    output = `git diff -U500 2>&1`
    unless $?.success?
      @display.timestamped_puts 'Warning: Failed to get git diff'.yellow
      return ''
    end
    output
  end

  def collect_file_contents
    return '' if git_repo?

    @display.timestamped_puts 'No git repository detected, collecting file contents...'.yellow

    exclusions = [
      '*.log', '*.tmp', '*.temp', '*.bak', '*.swp', '*.swo',
      '*.pyc', '*.pyo', '*.class', '*.jar', '*.war', '*.ear',
      '*.zip', '*.tar.gz', '*.tgz', '*.rar', '*.exe', '*.dll',
      '*.so', '*.dylib', '*.bin', '*.dat', '*.orig', '*.rej',
      '.DS_Store', 'Thumbs.db', '.git', '.gitignore'
    ]

    code_extensions = %w[
      .rb .py .js .ts .jsx .tsx .java .php .cpp .c .h .hpp .go .rs
      .sh .bash .zsh .html .css .scss .sass .yml .yaml .json .xml
      .erb .slim .swift .kt .scala .pl .pm .r .jl .md .txt
    ]

    files_content = []
    current_dir = Dir.pwd

    Dir.glob(File.join(current_dir, '**', '*')).each do |file_path|
      next unless File.file?(file_path)

      relative_path = file_path.sub("#{current_dir}/", '')
      basename = File.basename(relative_path)

      next if exclusions.any? { |pattern| File.fnmatch(pattern, basename) }
      next unless code_extensions.any? { |ext| relative_path.end_with?(ext) } ||
                  basename.start_with?('README') || basename == 'Makefile' || basename == 'Rakefile'

      begin
        content = File.read(file_path)
        files_content << "=== File: #{relative_path} ===\n#{content}\n"
      rescue StandardError => e
        @display.timestamped_puts "Warning: Failed to read #{relative_path}: #{e.message}".yellow
      end
    end

    files_content.join("\n")
  end

  def build_verification_system_instruction
    agents_content = load_agents_file
    has_agents = !agents_content.empty?

    instruction_parts = [
      <<~HEREDOC
        You are a tool that verifies whether code changes fully implement a requested feature.
      HEREDOC
    ]

    instruction_parts << "- Ruby development guidelines from AGENTS.md\n" if has_agents

    instruction_parts << <<~HEREDOC

      Task:
      Verify that the code changes fully implement the user's request without introducing bugs or regressions.

      Available information:
      - Git status and diff are provided in the prompt below (if git repository exists)
      - File contents are provided if no git repository is detected
      - Analyze the provided changes to verify they meet the requirements
      - Do not run any commands - all necessary data is already included

      Verification approach:
      - Review the git diff (or file contents if no git) to understand what changed
      - Check if the changes address the user's request
      - Look for potential bugs, regressions, or missing functionality
      - Verify code quality and adherence to project guidelines

      Response format:
      - Start your response with "YES: " followed by a brief description if verification passes
      - Start your response with "NO: " followed by a brief description if verification fails

      CRITICAL requirements:
      - Your response MUST start with either "YES" or "NO" as the first word
      - Use minimal formatting only - avoid excessive markdown or formatting
      - Keep your response short and concise - one sentence is sufficient
      - The description after YES/NO should be brief and specific
    HEREDOC

    if has_agents
      instruction_parts << <<~HEREDOC

        AGENTS.md content (development guidelines to consider):
        #{agents_content}
      HEREDOC
    end

    instruction_parts.join
  end

  def build_verification_user_content(user_request, status_output, diff_output, file_contents = '')
    content_parts = []
    current_size_bytes = 0
    max_size_bytes = MAX_CONTENT_SIZE_KB * 1024

    request_text = "User request: #{user_request}\n\n"
    current_size_bytes = append_section(content_parts, current_size_bytes, max_size_bytes, request_text)

    if git_repo?
      status_text = "Here is the git status:\n#{status_output.strip}\n\n"
      current_size_bytes = append_section(content_parts, current_size_bytes, max_size_bytes, status_text)

      unless diff_output.strip.empty?
        append_diff_section(content_parts, current_size_bytes, max_size_bytes, diff_output, 
status_output)
      end
    else
      no_git_text = "No git repository detected. Here are the file contents:\n\n"
      current_size_bytes = append_section(content_parts, current_size_bytes, max_size_bytes, no_git_text)

      unless file_contents.strip.empty?
        append_file_contents_section(content_parts, current_size_bytes, max_size_bytes, 
file_contents)
      else
        append_section(content_parts, current_size_bytes, max_size_bytes, 
"No files found to verify.")
      end
    end

    content_parts.join("\n")
  end

  def build_verification_prompt(req)
    status_output = collect_git_status
    prepare_untracked_files
    diff_output = collect_git_diff
    file_contents = collect_file_contents

    user_content = build_verification_user_content(req, status_output, diff_output, file_contents)

    <<~HEREDOC
      #{build_verification_system_instruction}

      ---

      #{user_content}
    HEREDOC
  end

  def run_verification(model, req)
    puts 'Verifying...'.blue

    verification_prompt = build_verification_prompt(req)
    success, output = @agent_executor.run(model, verification_prompt, verification_mode: true)
    return [false, 'Verification failed'] unless success

    verified, desc = parse_res(output.strip)
    [verified, desc || 'Failed']
  end

  def retry_with_fix(model, req)
    fix_prompt = build_fix_prompt(req)
    puts "Retrying #{model} with fix...".blue
    $stdout.puts ''

    success, _output = @agent_executor.run(model, fix_prompt)
    return [false, nil] unless success

    run_verification(model, req)
  end

  private

  def append_section(parts, current_size_bytes, max_size_bytes, text)
    return current_size_bytes if text.empty? || current_size_bytes + text.bytesize > max_size_bytes

    parts << text
    current_size_bytes + text.bytesize
  end

  def append_diff_section(parts, current_size_bytes, max_size_bytes, diff_output, status_output)
    diff_text = "Here is the git diff for all changes:\n\n"
    remaining = max_size_bytes - current_size_bytes - diff_text.bytesize
    if remaining > 0
      sorted_diff = @diff_processor.build_sorted_diff(diff_output, status_output, remaining)
      diff_text += sorted_diff
      parts << diff_text
      current_size_bytes + diff_text.bytesize
    else
      parts << "#{diff_text}(Diff truncated: exceeds #{MAX_CONTENT_SIZE_KB} KB limit)\n"
      current_size_bytes
    end
  end

  def append_file_contents_section(parts, current_size_bytes, max_size_bytes, file_contents)
    remaining = max_size_bytes - current_size_bytes
    return current_size_bytes if remaining <= 0

    if file_contents.bytesize <= remaining
      parts << file_contents.strip
      current_size_bytes + file_contents.bytesize
    else
      truncated = truncate_file_contents(file_contents, remaining)
      parts << truncated
      current_size_bytes + truncated.bytesize
    end
  end

  def truncate_file_contents(file_contents, max_bytes)
    return '' if max_bytes <= 0

    truncated = file_contents.byteslice(0, max_bytes)
    last_newline = truncated.rindex("\n")
    return truncated if last_newline.nil?

    "#{truncated.byteslice(0, last_newline + 1)}\n... (file contents truncated due to size limit)\n"
  end
end

# Main orchestrator class for superagent execution
class Superagent
  NON_INTERACTIVE_NOTICE = /
    (?:^|\n)
    IMPORTANT:\s+This\s+agent\s+is\s+running\s+in\s+non-interactive\s+mode\.
    .*?
    Execute\s+tasks\s+directly\s+without\s+seeking\s+clarification\.
    \s*
  /mix
  MODELS = %w[
    auto
    gemini-3-flash
    gpt-5.2-codex
    gemini-3-pro
    composer-1
    claude-4.5-sonnet
    claude-4.5-opus
  ].freeze

  def initialize(display: Display.new, request_reader: nil, agent_executor: nil, verification_handler: nil)
    @display = display
    @request_reader = request_reader || RequestReader.new(@display)
    @agent_executor = agent_executor || AgentExecutor.new(@display)
    @verification_handler = verification_handler || VerificationHandler.new(@display, @agent_executor)
    @start_time = nil
    @current_pass = nil
    @current_model = nil
    @current_model_index = 0
  end

  def run(start_model_index: 0, request: nil)
    initialize_run(request)
    req = sanitize_request(request || @request_reader.read)
    @request_reader.validate(req)
    @display.display_start_message(req)

    return run_plan_mode(req) if @request_reader.plan_mode

    execute_attempts(start_model_index, req)
    handle_final_failure unless @last_attempt_success
  end

  def run_plan_mode(req)
    update_terminal_title('Planning...')
    puts 'Running in plan mode...'.cyan
    $stdout.puts ''

    MODELS.each_with_index do |model, idx|
      @current_pass = idx + 1
      @current_model = model
      update_terminal_title("Planning: #{model}")
      @display.display_attempt_header(model, idx, MODELS.size)

      success, output = @agent_executor.run_plan_mode(model, req)
      return handle_plan_success if success

      @display.display_agent_failure(output)
    end

    handle_final_failure
  end

  private

  def initialize_run(request)
    update_terminal_title('Initializing...')
    @display.check_late_night_reminder
    @start_time = Time.now unless request
    @display.suggest_git_init unless request
    @display.update_git_status unless request
  end

  def execute_attempts(start_index, req)
    @current_model_index = start_index
    MODELS[@current_model_index..-1].each_with_index do |model, relative_idx|
      idx = @current_model_index + relative_idx
      @current_pass = idx + 1
      @current_model = model
      update_terminal_title("Attempting: #{model}")
      @display.display_attempt_header(model, idx, MODELS.size)

      success, output = @agent_executor.run(model, req)
      unless success
        @display.display_agent_failure(output)
        next
      end

      break if process_model_attempt(model, req) == :success
    end
  end

  def process_model_attempt(model, req)
    update_terminal_title("Verifying: #{model}")
    verified, desc = @verification_handler.run_verification(model, req)
    $stdout.puts ''

    if verified
      handle_success(desc)
      handle_final_success(req)
      @last_attempt_success = true
      return :success
    end

    @display.display_verification_result(false, desc)
    $stdout.puts ''

    update_terminal_title("Retrying: #{model}")
    verified, fix_desc = @verification_handler.retry_with_fix(model, req)
    $stdout.puts ''

    if verified
      handle_success(fix_desc, 'after retry')
      handle_final_success(req)
      @last_attempt_success = true
      return :success
    end

    @last_attempt_success = false

    @display.display_verification_result(false, fix_desc, 'after retry')
    $stdout.puts ''
    :continue
  end


  def handle_success(desc, context = '')
    @display.display_verification_result(true, desc, context)
    @display.display_total_runtime(@start_time)
    @display.display_git_status
  end

  def handle_final_success(previous_req = nil)
    CompletionNotifier.notify_completion(success: true)
    update_terminal_title(true)

    return unless $stdin.tty?

    lock_path = InstanceLock.current_lock_path
    InstanceLock.release_lock(lock_path) if lock_path

    update_terminal_title('✅ Passed')
    $stdout.puts ''
    puts 'Enter the new request:'.cyan
    puts '(Press Enter twice, Ctrl+D, or Ctrl+C to submit/exit)'
    $stdout.puts ''

    new_req = sanitize_request(read_next_request)
    return unless new_req && !new_req.strip.empty?

    new_lock_path = InstanceLock.acquire_lock
    unless new_lock_path
      puts 'Failed to acquire instance lock. Exiting.'.red
      exit 1
    end

    is_fix_or_improvement = detect_fix_or_improvement(new_req, previous_req)
    start_index = is_fix_or_improvement ? @current_model_index : 0
    start_index = [[start_index, 0].max, MODELS.size - 1].min

    $stdout.puts ''
    puts "Starting #{is_fix_or_improvement ? 'continuation' : 'new request'} from #{MODELS[start_index]}...".yellow
    $stdout.puts ''

    @request_reader = RequestReader.new(@display)
    @request_reader.instance_variable_set(:@plan_mode, false)
    run(start_model_index: start_index, request: new_req)
  end

  def handle_plan_success
    @display.display_total_runtime(@start_time)
    @display.display_git_status
    CompletionNotifier.notify_completion(success: true)
    update_terminal_title(true)
    exit 0
  end

  def handle_final_failure
    @display.display_all_attempts_failed
    @display.display_total_runtime(@start_time)
    @display.display_git_status
    CompletionNotifier.notify_completion(success: false)
    update_terminal_title(false)
    exit 1
  end

  def update_terminal_title(phase)
    return unless $stdout.tty? || $stderr.tty?

    title = case phase
            when true then '✅ Done'
            when false then '❌ Error'
            else phase.to_s
            end
    sequence = "\033]0;#{title}\007"
    $stderr.print sequence if $stderr.tty?
    $stderr.flush if $stderr.tty?
  rescue StandardError
    # Ignore terminal title update errors
  end

  def read_next_request
    lines = []
    loop do
      line = read_next_request_line(lines)
      return nil if line.nil?
      break if line == :done
      next if line == :continue

      lines << line
    end
    result = lines.join("\n")
    result.strip.empty? ? nil : result
  end

  def read_next_request_line(lines)
    line = Reline.readline(lines.empty? ? '> ' : '  ', true)
    return nil if line.nil?

    line = line.strip
    return :done if line.empty? && !lines.empty?
    return :continue if line.empty?

    line
  rescue Interrupt
    $stdout.puts ''
    puts 'Interrupted. Exiting.'.yellow
    exit 0
  rescue StandardError => e
    puts "Error reading input: #{e.message}".yellow
    return nil
  end

  def detect_fix_or_improvement(new_req, previous_req)
    return false if previous_req.nil? || new_req.nil?

    new_lower = new_req.downcase
    prev_lower = previous_req.downcase

    return true if check_keywords(new_lower)

    new_words = new_lower.split(/\s+/)
    prev_words = prev_lower.split(/\s+/)
    common_words = new_words & prev_words
    common_ratio = common_words.size.to_f / [new_words.size, prev_words.size].max

    common_ratio > 0.3
  end

  def check_keywords(new_lower)
    fix_keywords = %w[fix bug error issue problem broken wrong incorrect failed failure]
    improvement_keywords = %w[improve enhance better optimize refine adjust modify update change]
    continuation_keywords = %w[also and continue add more]

    is_fix = fix_keywords.any? { |keyword| new_lower.include?(keyword) }
    is_improvement = improvement_keywords.any? { |keyword| new_lower.include?(keyword) }
    is_continuation = continuation_keywords.any? { |keyword|
 new_lower.start_with?(keyword) || new_lower.match?(/\b#{keyword}\s/) }

    is_fix || is_improvement || is_continuation
  end

  def sanitize_request(req)
    return req if req.nil?

    cleaned = req.gsub(NON_INTERACTIVE_NOTICE, "\n").strip
    cleaned.gsub(/\n{3,}/, "\n\n")
  end
end

if __FILE__ == $PROGRAM_NAME
  CompletionNotifier.setup_exit_hook
  display = Display.new
  lock_path = nil
  request_reader = RequestReader.new(display)
  pre_read_request = nil
  
  begin
    if InstanceLock.lock_exists?
      $stdout.puts ''
      puts 'Another instance is running in the current directory.'.yellow
      puts 'You can enter your request now. It will be processed after the current instance completes.'.yellow
      $stdout.puts ''
      pre_read_request = request_reader.read
      request_reader.validate(pre_read_request)
      $stdout.puts ''
      puts 'Waiting for the current instance to complete...'.yellow
      $stdout.puts ''
    end
    
    lock_path = InstanceLock.acquire_lock
    
    unless lock_path
      puts 'Failed to acquire instance lock. Exiting.'.red
      exit 1
    end
    
    Superagent.new(display: display, request_reader: request_reader).run(request: pre_read_request)
  ensure
    InstanceLock.release_lock(lock_path) if lock_path
  end
end
