# frozen_string_literal: true

require 'open3'
require 'json'
require 'rbconfig'
require 'timeout'

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
    return [nil, nil, nil, nil] if line.nil? || line.strip.empty? || line.include?('=>')
    return [nil, nil, nil, nil] if (line.include?('"role"') || line.include?("'role'") || line.include?(':role')) &&
                        (line.include?('"user"') || line.include?("'user'") || line.include?(':user'))

    json_obj = JSON.parse(line.strip)
    type = json_obj['type']
    text = extract_text_from_json(json_obj)
    command = extract_command_from_json(json_obj)

    text = text.to_s unless text.nil?
    text = nil if text&.empty?
    
    # Generate stream ID from type and request_id if available
    stream_id = json_obj['request_id'] || json_obj['stream_id'] || type
    [type, text, stream_id, command]
  rescue JSON::ParserError
    [nil, nil, nil, nil]
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

  def extract_command_from_json(json_obj)
    # Check for explicit command field
    return json_obj['command'] if json_obj['command']

    # Check tool_call for command information
    if json_obj['type'] == 'tool_call' || json_obj['type'] == 'tool_result'
      tool_call = json_obj['tool_call'] || json_obj
      
      # Check function name and arguments
      if tool_call.dig('function', 'name')
        func_name = tool_call.dig('function', 'name')
        func_args = tool_call.dig('function', 'arguments')
        
        # If it's a run/execute function, extract the command from arguments
        if func_name.match?(/^(run|execute|command)/i) && func_args
          begin
            args = func_args.is_a?(String) ? JSON.parse(func_args) : func_args
            return args['command'] || args['cmd'] || args['input'] if args.is_a?(Hash)
            return func_args if func_args.is_a?(String) && func_args.match?(/^[a-zA-Z0-9_\-\.\/\s]+$/)
          rescue JSON::ParserError
            return func_args if func_args.is_a?(String) && func_args.length < 200
          end
        end
      end
      
      # Check for direct command in tool_call
      input = tool_call['input']
      if input.is_a?(String) && input.match?(/^[a-zA-Z0-9_\-\.\/\s]+$/) && input.length < 200
        return input
      end
      return tool_call['command'] if tool_call['command']
    end

    # Check for command in text content
    text = extract_text_from_json(json_obj)
    return extract_command_from_text(text) if text

    nil
  end

  def extract_command_from_text(text)
    return nil unless text.is_a?(String)

    # Look for patterns like "Running: command" or commands in backticks
    patterns = [
      /Running:\s*([^\n]+)/i,
      /Executing:\s*([^\n]+)/i,
      /Command:\s*([^\n]+)/i,
      /`([^`]+)`/  # Backtick-wrapped commands (most reliable)
    ]

    patterns.each do |pattern|
      match = text.match(pattern)
      if match && match[1]
        cmd = match[1].strip
        # Only return if it looks like an actual command
        # Commands typically have: executable names, paths, flags, or are short common commands
        return cmd if looks_like_command?(cmd)
      end
    end

    nil
  end

  def looks_like_command?(cmd)
    return false if cmd.length < 2 || cmd.length > 500
    return false unless cmd.match?(/^[a-zA-Z0-9_\-\.\/\s\:\;\,\|\&\<\>\(\)\"\']+$/)

    # Must contain at least one of: executable name, path separator, flag, or be a common short command
    cmd.match?(/\b(rspec|rake|make|npm|yarn|bundle|ruby|python|node|go| cargo|test|spec|build|run)\b/i) ||
      cmd.include?('/') ||
      cmd.include?('-') ||
      cmd.include?('--') ||
      cmd.match?(/^[a-z]+\s+[a-z]/i)  # "cmd arg" pattern
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
    @display.puts "Running: #{display_cmd}"
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
      @display.puts '⚠️  Test runner already running in system, no timeout applied'.yellow
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
            @display.puts '⚠️  Test runner detected (child of agent), disabling timeout'.yellow
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
            @display.puts "❌ Agent timed out after #{MAX_EXECUTION_TIMEOUT}s maximum execution time".red
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
          @display.puts "❌ Agent timed out after #{EXECUTION_TIMEOUT}s without receiving data".red
          Process.kill('TERM', process_pid) if process_pid
          sleep 2
          Process.kill('KILL', process_pid) if process_pid && !execution_complete
          break
        end
      end
    end

    begin
      @display.reset_stream_tracking
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

                type, text, stream_id, command = parse_json_stream_line(line.strip)
                if command && !command.empty?
                  @display.puts "Running: #{command}".green
                end
                if text && !text.empty?
                  if type == 'result'
                    final_result = text
                  else
                    @display.print_word(text, stream_id: stream_id)
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

                  type, text, stream_id, command = parse_json_stream_line(line.strip)
                  if command && !command.empty?
                    @display.puts "Running: #{command}".green
                  end
                  if text && !text.empty?
                    if type == 'result'
                      final_result = text
                    else
                      @display.print_word(text, stream_id: stream_id)
                    end
                  end
                end
              end
            rescue EOFError
              # Stream closed, no more data
            rescue IOError => e
              # Error reading remaining data, log and continue
              @display.puts "Warning: Error reading remaining output: #{e.message}".yellow
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
          type, text, stream_id, command = parse_json_stream_line(line_buffer.strip)
          if command && !command.empty?
            @display.puts "Running: #{command}".green
          end
          if text && !text.empty?
            if type == 'result'
              final_result = text
            else
              @display.print_word(text, stream_id: stream_id)
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
    @display.reset_stream_tracking
    cmd = build_and_display_command('--model', model, wrapped, verification_mode: verification_mode)
    stdout, stderr, status = Open3.capture3(*cmd)
    raw_output = stdout + stderr
    final_result = ''

    raw_output.each_line do |line|
      type, text, stream_id, command = parse_json_stream_line(line.strip)
      if command && !command.empty?
        @display.puts "Running: #{command}".green
      end
      if text && !text.empty?
        if type == 'result'
          final_result = text
        else
          @display.print_word(text, stream_id: stream_id)
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
        @display.puts "❌ Agent execution error: #{e.message}".red
        return [false, "Execution error: #{e.message}"]
      end

      output = (stdout || '') + (stderr || '')
      # Output is already processed and displayed by run_with_timeout_monitoring
      return [status.success?, output] if status.success?

      if retryable_network_error?(output) && retries < max_retries
        retries += 1
        delay = base_delay * (2**(retries - 1))
        @display.puts "⚠️  Network error, retrying in #{delay}s... (#{retries}/#{max_retries})".yellow
        sleep(delay)
        next
      end

      return [false, output]
    end
  end

  def run_plan_mode(model, p)
    @display.reset_stream_tracking
    wrapped = wrap_prompt(p)
    cmd = build_and_display_command('--plan', '--model', model, wrapped)
    
    stdout, stderr, status = Open3.capture3(*cmd)
    raw_output = (stdout || '') + (stderr || '')
    final_result = ''
    
    raw_output.each_line do |line|
      type, text, stream_id, command = parse_json_stream_line(line.strip)
      if command && !command.empty?
        @display.puts "Running: #{command}".green
      end
      if text && !text.empty?
        if type == 'result'
          final_result = text
        else
          @display.print_word(text, stream_id: stream_id)
        end
      end
    end
    
    # Flush any remaining buffered text
    @display.flush_word_buffer
    
    output = final_result.empty? ? raw_output : final_result
    [status.success?, output]
  rescue StandardError => e
    @display.puts "❌ Agent execution error: #{e.message}".red
    [false, "Execution error: #{e.message}"]
  end
end
