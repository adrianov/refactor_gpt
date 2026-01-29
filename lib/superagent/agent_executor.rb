# frozen_string_literal: true

require 'open3'
require 'json'
require 'rbconfig'
require 'timeout'
require_relative '../agents_file_handler'

# Handles agent command execution with retry logic
class AgentExecutor
  include AgentsFileHandler
  EXECUTION_TIMEOUT = 60
  MAX_EXECUTION_TIMEOUT = 600
  CONTEXT_MAX_LINES = 500
  TEST_RUNNERS = %w[rspec minitest test-unit cucumber jest mocha pytest].freeze
  TEST_RUNNER_CHECK_INTERVAL = 2

  attr_reader :agent_session_id

  def initialize(display, session_tracker: nil)
    @display = display
    @tools_used = []
    @session_tracker = session_tracker
    @agent_session_id = nil
  end

  def reset_agent_session
    @agent_session_id = nil
  end

  def resume_with_session_id(id)
    @agent_session_id = id
  end

  def test_runner_running?(pid = nil)
    return false unless RbConfig::CONFIG['host_os'] =~ /linux|darwin|bsd/

    TEST_RUNNERS.any? do |runner|
      if pid
        descendants = get_all_descendants(pid)
        descendants.any? { |d_pid| process_matches_runner?(d_pid, runner) }
      else
        system_runner_running?(runner)
      end
    end
  end

  def system_runner_running?(runner)
    return true if system("pgrep -x #{runner} > #{File::NULL} 2>&1")

    output = `ps ax -o comm,args 2>/dev/null`
    return false if output.empty?

    output.each_line.any? { |line| line_matches_runner?(line, runner) }
  end

  def line_matches_runner?(line, runner)
    return false if line.strip.empty?

    comm, args = line.split(nil, 2)
    return false if args.nil? || !%w[ruby node python].include?(comm)
    return false unless args.match?(/\b(?:bundle\s+exec\s+)?#{runner}(?:\s|$)/)

    !args.match?(/\b(?:grep|find|vim|nano|emacs|less|more|cat|head|tail|ag|rg)\s/)
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
      if (children = p_to_c[curr])
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

  def wrap_prompt(p, new_session: false)
    parts = []
    parts << guidelines_section
    parts << git_diff_section(new_session)
    parts << working_tree_section(new_session)
    parts << summary_section
    parts << history_section
    parts << non_interactive_notice
    p + parts.compact.join
  end

  def git_diff_section(new_session)
    return nil unless new_session
    out = `git diff 2>#{File::NULL}`.strip
    return nil if out.empty?
    lines = out.split("\n", -1)
    truncated = lines.size > CONTEXT_MAX_LINES
    text = lines.first(CONTEXT_MAX_LINES).join("\n")
    text += "\n\n(truncated to #{CONTEXT_MAX_LINES} lines)" if truncated
    "\n\nGit diff (max #{CONTEXT_MAX_LINES} lines):\n#{text}"
  end

  def working_tree_section(new_session)
    return nil unless new_session
    out = `bfs --nohidden 2>#{File::NULL}`.strip
    return nil if out.empty?
    lines = out.split("\n", -1)
    truncated = lines.size > CONTEXT_MAX_LINES
    text = lines.first(CONTEXT_MAX_LINES).join("\n")
    text += "\n\n(truncated to #{CONTEXT_MAX_LINES} lines)" if truncated
    "\n\nWorking tree (bfs --nohidden, max #{CONTEXT_MAX_LINES} lines):\n#{text}"
  end

  def guidelines_section
    content = load_agents_content
    return nil if content.nil? || content.strip.empty?

    "\n\nProject guidelines (from AGENTS.md or AGENTS.rb):\n#{content.strip}"
  end

  def summary_section
    summary = @session_tracker&.get_last_agent_summary
    return nil if summary.nil? || summary.strip.empty?

    "\n\nFinal summary from previous agent run:\n#{summary.strip}"
  end

  def history_section
    history = @session_tracker&.get_session_request_history || []
    return nil if history.empty?

    "\n\nPrevious requests in this session:\n" +
      history.map.with_index(1) { |req, idx| "#{idx}. #{req}" }.join("\n")
  end

  def non_interactive_notice
    "\n\nIMPORTANT: This agent runs in non-interactive mode. " \
    "You must make all decisions autonomously and execute tasks directly " \
    "without requesting user input, clarification, or confirmation. " \
    "Proceed with implementation based on the available context and your best judgment."
  end

  def load_agents_content
    project_root = Dir.pwd
    agents_rb = File.join(project_root, 'AGENTS.rb')
    agents_md = File.join(project_root, 'AGENTS.md')
    
    if File.exist?(agents_rb)
      File.read(agents_rb)
    elsif File.exist?(agents_md)
      File.read(agents_md)
    else
      ''
    end
  end

  def parse_json_stream_line(line)
    return [nil] * 5 if line.nil? || line.strip.empty? || line.include?('=>')
    return [nil] * 5 if line.match?(/[:"']role["']/) && line.match?(/[:"']user["']/)

    json_obj = JSON.parse(line.strip)
    type = json_obj['type']
    return [nil] * 5 if type == 'thinking' && (json_obj['text'].nil? || json_obj['text'].empty?)

    extract_session_id(json_obj)

    [type, extract_text_from_json(json_obj)&.to_s, json_obj['request_id'] || json_obj['stream_id'] || type,
     extract_command_from_json(json_obj),
     (extract_tool_call_info(json_obj) if %w[tool_call tool_result].include?(type))]
  rescue JSON::ParserError
    [nil] * 5
  end

  def extract_session_id(json_obj)
    return unless json_obj['session_id']
    @agent_session_id ||= json_obj['session_id']
  end

  def extract_text_from_json(json_obj)
    case json_obj['type']
    when 'assistant'
      content = json_obj.dig('message', 'content')
      if content.is_a?(Array)
        text_content = content.find { |c| c['type'] == 'text' }
        text = text_content ? text_content['text'] : nil
        return text if text && !text.strip.empty?
      elsif content.is_a?(String) && !content.strip.empty?
        return content
      end
      json_obj.dig('message', 'text') || json_obj['text']
    when 'result'
      json_obj['result']
    when 'thinking'
      text = json_obj['text']
      return nil if text.nil? || text.strip.empty?
      text
    when 'step', 'tool_call', 'tool_result'
      json_obj['step'] || json_obj['text'] || json_obj['content'] || json_obj['result']
    else
      json_obj['text'] || json_obj['content'] || json_obj['result'] || json_obj['message']
    end
  end

  def extract_command_from_json(json_obj)
    return json_obj['command'] if json_obj['command']

    if %w[tool_call tool_result].include?(json_obj['type'])
      tool_call = json_obj['tool_call'] || json_obj
      func_name = tool_call.dig('function', 'name')
      func_args = tool_call.dig('function', 'arguments')
      
      if func_name&.match?(/^(run|execute|command)/i) && func_args
        begin
          args = func_args.is_a?(String) ? JSON.parse(func_args) : func_args
          return args['command'] || args['cmd'] || args['input'] if args.is_a?(Hash)
          return func_args if func_args.is_a?(String) && func_args.match?(/^[a-zA-Z0-9_\-\.\/\s]+$/)
        rescue JSON::ParserError
          return func_args if func_args.is_a?(String) && func_args.length < 200
        end
      end
      
      input = tool_call['input']
      return input if input.is_a?(String) && input.match?(/^[a-zA-Z0-9_\-\.\/\s]+$/) && input.length < 200
      return tool_call['command'] if tool_call['command']
    end

    extract_command_from_text(extract_text_from_json(json_obj))
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

  def extract_tool_call_info(json_obj)
    return nil unless %w[tool_call tool_result].include?(json_obj['type'])

    tool_call = json_obj['tool_call'] || json_obj
    func_name = extract_tool_name(tool_call, json_obj)
    return nil unless func_name

    tool_info = { name: func_name, arguments: parse_tool_args(extract_tool_args(tool_call, json_obj)), 
subtype: json_obj['subtype'] }
    @tools_used << tool_info.dup unless @tools_used.any? { |t|
 t[:name] == func_name && t[:subtype] == tool_info[:subtype] }
    
    tool_info
  end

  def extract_tool_name(tool_call, json_obj)
    func_name = tool_call.dig('function', 'name') || json_obj['function_name'] || json_obj['name']
    return func_name if func_name

    tool_call.keys.each do |key|
      next unless key.end_with?('ToolCall') || key.end_with?('Call')
      tool_key = key.sub(/ToolCall$/, '').sub(/Call$/, '')
      return format_tool_name(tool_key)
    end

    nil
  end

  def format_tool_name(name)
    name = name.sub(/^[a-z]/, &:upcase) if name.match?(/^[a-z]/)
    formatted = name.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
    formatted = formatted.sub(/_tool$/, '')
    formatted
  end

  def extract_tool_args(tool_call, json_obj)
    func_args = tool_call.dig('function', 'arguments') || json_obj['arguments'] || json_obj['args']
    return func_args if func_args

    tool_call.each do |key, value|
      next unless key.end_with?('ToolCall') || key.end_with?('Call')
      return value['args'] if value.is_a?(Hash) && value['args']
      return value if value.is_a?(Hash)
    end

    nil
  end

  def parse_tool_args(func_args)
    return func_args unless func_args.is_a?(String)

    JSON.parse(func_args)
  rescue JSON::ParserError
    func_args
  end

  def looks_like_command?(cmd)
    return false if cmd.length < 2 || cmd.length > 500
    return false unless cmd.match?(/^[a-zA-Z0-9_\-\.\/\s\:\;\,\|\&\<\>\(\)\"\']+$/)

    cmd.match?(/\b(rspec|rake|make|npm|yarn|bundle|ruby|python|node|go| cargo|test|spec|build|run)\b/i) ||
      cmd.match?(/[\/\-]/) ||
      cmd.match?(/^[a-z]+\s+[a-z]/i)
  end

  def build_command(model:, plan_mode: false, verification_mode: false)
    cmd = %w[
      agent
      --print
      --output-format
      stream-json
      --force
    ]
    cmd << '--plan' if plan_mode
    cmd.concat(['--mode', 'ask']) if verification_mode
    cmd.concat(['--resume', @agent_session_id]) if @agent_session_id
    cmd.concat(['--model', model])
    cmd
  end

  def display_command(cmd, prompt)
    display_prompt = prompt.length > 50 || prompt.include?("\n") ? "'#{prompt[0..50].gsub("\n", " ")}...'" : prompt
    @display.puts "Running: #{cmd.join(' ')} #{display_prompt}"
  end

  RECOVERABLE_NETWORK_RETRIES = 2

  def retryable_network_error?(output)
    return false if output.to_s.empty?

    output.match?(/CANCEL|canceled|stream closed|0x8|http\/2 stream closed|Connection stalled/i)
  end

  UNRECOVERABLE_PHRASES = %w[503 502 404].freeze
  UNRECOVERABLE_MODEL_PHRASES = %w[not found not available unavailable invalid].freeze

  def unrecoverable_network_error?(output)
    return false if output.to_s.empty?

    n = output.downcase
    UNRECOVERABLE_PHRASES.any? { |p| n.include?(p) } ||
      (n.include?('rate limit') && n.include?('exceeded')) ||
      (n.include?('model') && UNRECOVERABLE_MODEL_PHRASES.any? { |p| n.include?(p) })
  end

  def run_with_timeout_monitoring(model, wrapped, verification_mode: false)
    @tools_used = []
    @verification_mode = verification_mode
    return run_without_timeout(model, wrapped, verification_mode: verification_mode) if test_runner_running?

    @state = { detected: false, complete: false, pid: nil, disabled: false, timed_out: false, last_chunk: nil, 
start: nil }
    monitor_thread = start_monitor_thread
    timeout_thread = start_timeout_thread

    begin
      execute_agent_process(model, wrapped, verification_mode: verification_mode)
    ensure
      @state[:complete] = true
      monitor_thread&.kill
      timeout_thread&.kill
    end
  end

  def run_plan_mode(model, p, new_session: false)
    @tools_used = []
    @display.reset_stream_tracking
    wrapped = wrap_prompt(p, new_session: new_session)
    cmd = build_command(model: model, plan_mode: true)
    display_command(cmd, wrapped)
    
    raw, final = '', ''
    begin
      Open3.popen2e(*cmd) do |stdin, stdout_stderr, wait_thr|
        stdin.write(wrapped)
        stdin.close
        stdout_stderr.each_line do |line|
          raw += line
          final = process_json_stream_line(line, final)
        end
        status = wait_thr.value
        @display.flush_word_buffer
        display_tools_summary
        [status.success?, final.empty? ? raw : final]
      end
    rescue StandardError => e
      @display.puts "❌ Agent execution error: #{e.message}".red
      [false, "Execution error: #{e.message}"]
    end
  end

  def run(model, p, base_delay: 1, verification_mode: false, new_session: false)
    wrapped = wrap_prompt(p, new_session: new_session)
    retries = 0
    loop do
      stdout, _, status = run_with_timeout_monitoring(model, wrapped, verification_mode: verification_mode)
      output = stdout || ''
      return [true, output, nil] if status&.success?
      
      reason = if (status.nil? || !status.success?) && stdout.nil?
                 :recoverable
               elsif unrecoverable_network_error?(output)
                 :unrecoverable
               elsif retryable_network_error?(output) || output.include?('Timeout after')
                 :recoverable
               end

      if reason == :recoverable && retries < RECOVERABLE_NETWORK_RETRIES
        retries += 1
        delay = base_delay * (2**(retries - 1))
        @display.puts "⚠️  Network error, retrying in #{delay}s... (#{retries}/#{RECOVERABLE_NETWORK_RETRIES})".yellow
        sleep(delay)
        next
      end
      return [false, output, reason]
    end
  rescue StandardError => e
    @display.puts "❌ Agent execution error: #{e.message}".red
    [false, "Execution error: #{e.message}", :unrecoverable]
  end

  def run_without_timeout(model, wrapped, verification_mode: false)
    @tools_used = []
    @verification_mode = verification_mode
    @display.reset_stream_tracking
    cmd = build_command(model: model, verification_mode: verification_mode)
    display_command(cmd, wrapped)
    
    raw, final = '', ''
    begin
      Open3.popen2e(*cmd) do |stdin, stdout_stderr, wait_thr|
        stdin.write(wrapped)
        stdin.close
        stdout_stderr.each_line do |line|
          raw += line
          final = process_json_stream_line(line, final)
        end
        finalize_execution(raw, final, wait_thr)
      end
    rescue StandardError => e
      @display.puts "❌ Agent execution error: #{e.message}".red
      [nil, nil, Struct.new(:success?).new(false)]
    end
  end

  def process_json_stream_line(line, final)
    type, text, stream_id, command, tool = parse_json_stream_line(line.strip)
    @display.display_tool_call(tool) if tool
    @display.puts "Running: #{command}".green if command && !command.empty?
    return final unless text && !text.empty?

    case type
    when 'result'
      text
    when 'thinking'
      @display.print_thinking_indicator
      final
    when 'assistant', nil
      @display.print_word(text, stream_id: stream_id)
      final
    else
      final
    end
  end

  private

  def start_monitor_thread
    Thread.new do
      loop do
        sleep TEST_RUNNER_CHECK_INTERVAL
        break if @state[:complete]
        if @state[:pid] && !@state[:detected] && test_runner_running?(@state[:pid])
          @state[:detected] = @state[:disabled] = true
          @display.puts '⚠️  Test runner detected (child of agent), disabling timeout'.yellow
        end
      end
    end
  end

  def start_timeout_thread
    Thread.new do
      until @state[:complete]
        sleep TEST_RUNNER_CHECK_INTERVAL
        next if @state[:disabled] || (@state[:pid] && test_runner_running?(@state[:pid]))
        check_timeouts
      end
    end
  end

  def check_timeouts
    now = Time.now
    if @state[:start] && (now - @state[:start]) >= MAX_EXECUTION_TIMEOUT
      terminate_agent("maximum execution time (#{MAX_EXECUTION_TIMEOUT}s)")
    elsif @state[:last_chunk] && (now - @state[:last_chunk]) >= EXECUTION_TIMEOUT
      terminate_agent("no data received (#{EXECUTION_TIMEOUT}s)")
    end
  end

  def terminate_agent(reason)
    @state[:timed_out] = true
    @display.puts "❌ Agent timed out after #{reason}".red
    return unless @state[:pid]
    Process.kill('TERM', @state[:pid])
    sleep 2
    Process.kill('KILL', @state[:pid]) unless @state[:complete]
  end

  def execute_agent_process(model, wrapped, verification_mode: false)
    @display.reset_stream_tracking
    cmd = build_command(model: model, verification_mode: verification_mode)
    display_command(cmd, wrapped)
    Open3.popen2e(*cmd) do |stdin, stdout_stderr, wait_thr|
      @state[:pid] = wait_thr.pid
      @state[:start] = @state[:last_chunk] = Time.now
      stdin.write(wrapped)
      stdin.close
      process_agent_output(stdout_stderr, wait_thr)
    end
  end

  def process_agent_output(stdout_stderr, wait_thr)
    raw, final, buffer = '', '', ''
    loop do
      break if @state[:timed_out]
      if IO.select([stdout_stderr], nil, nil, 0.5)
        begin
          chunk = stdout_stderr.readpartial(4096)
          @state[:last_chunk] = Time.now
          raw += chunk
          buffer += chunk
          buffer, final = process_buffer(buffer, final)
        rescue EOFError then break
        end
      elsif !wait_thr.alive?
        process_remaining_output(stdout_stderr, raw, final, buffer)
        break
      end
    end
    finalize_execution(raw, final, wait_thr)
  end

  def process_remaining_output(stdout_stderr, _raw, final, buffer)
    remaining = stdout_stderr.read rescue nil
    if remaining
      buffer += remaining
      _, _ = process_buffer(buffer, final)
    end
  end

  def process_buffer(buffer, final)
    while (idx = buffer.index("\n"))
      line = buffer[0..idx].strip
      buffer = buffer[(idx + 1)..-1] || ''
      final = process_json_stream_line(line, final)
    end
    [buffer, final]
  end

  def finalize_execution(raw, final, wait_thr)
    @display.flush_word_buffer
    display_tools_summary
    status = wait_thr.value rescue Struct.new(:success?).new(false)
    status = Struct.new(:success?).new(false) if @state && @state[:timed_out]
    [final.empty? ? raw : final, '', status]
  end

  def display_tools_summary
    return if @tools_used.empty?

    $stdout.puts ''
    @display.puts "Tools applied (#{@tools_used.size}):".cyan
    @tools_used.each do |tool|
      args_str = @display.format_tool_call_args(tool[:arguments])
      display_text = args_str ? "  • #{tool[:name]}(#{args_str})" : "  • #{tool[:name]}"
      $stdout.puts display_text.colorize(:light_blue)
    end
    $stdout.puts ''
  end
end
