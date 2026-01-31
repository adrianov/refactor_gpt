# frozen_string_literal: true

require 'open3'
require 'json'
require 'oj'
require 'rbconfig'
require 'timeout'
# Handles agent command execution with retry logic
class AgentExecutor
  EXECUTION_TIMEOUT = 60
  MAX_EXECUTION_TIMEOUT = 600
  CONTEXT_MAX_LINES = 500
  TEST_RUNNERS = %w[rspec minitest test-unit cucumber jest mocha pytest].freeze
  TEST_RUNNER_CHECK_INTERVAL = 2

  attr_reader :agent_session_id

  def initialize(display, session_tracker: nil, show_prompt: false)
    @display = display
    @tools_used = []
    @session_tracker = session_tracker
    @agent_session_id = nil
    @compact_pass_run = false
    @state_mutex = Mutex.new
    @model_call_finished_since_compact = false
    @full_prompt_buffer = nil
    @show_prompt = show_prompt
    @verification_mode = false
  end

  def reset_agent_session
    @agent_session_id = nil
    @compact_pass_run = false
    @model_call_finished_since_compact = false
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
    return false if line.to_s.strip.empty?

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
    cmdline = `ps -p #{pid} -o args= 2>/dev/null`.to_s.strip
    cmdline.include?(runner)
  end

  def wrap_prompt(p, new_session: false, current_request: nil)
    parts = []
    if new_session
      parts << non_interactive_notice
      parts << guidelines_section(always_include: true)
    end
    parts << user_context_section
    parts << git_status_section(new_session)
    parts << git_diff_section(new_session)
    parts << working_tree_section(new_session)
    rest = parts.compact.join
    history = @verification_mode ? nil : history_section(current_request: current_request)
    summary = summary_section
    p + (history.to_s + summary.to_s + rest)
  end

  def user_context_section
    parts = []
    parts << "Current time: #{Time.now.strftime("%A, %B %d, %Y at %I:%M %p %Z")}"
    parts << "OS: #{RbConfig::CONFIG['host_os']}"
    parts << "Shell: #{ENV['SHELL']}"
    parts << "User: #{ENV['USER'] || ENV['USERNAME']}"
    parts << "Project root: #{Dir.pwd}"
    "\n\n" + parts.join("\n")
  end

  def git_status_section(new_session)
    return nil unless new_session
    out = `git status 2>#{File::NULL}`.to_s.strip
    return nil if out.empty?
    "\n\nGit status:\n#{out}"
  end

  def git_diff_section(new_session)
    return nil unless new_session
    out = `git diff 2>#{File::NULL}`.to_s.strip
    return nil if out.empty?
    lines = out.split("\n", -1)
    truncated = lines.size > CONTEXT_MAX_LINES
    text = lines.first(CONTEXT_MAX_LINES).join("\n")
    text += "\n\n(truncated to #{CONTEXT_MAX_LINES} lines)" if truncated
    "\n\nGit diff (max #{CONTEXT_MAX_LINES} lines):\n#{text}"
  end

  def working_tree_section(new_session)
    return nil unless new_session
    out = `bfs --nohidden 2>#{File::NULL}`.to_s.strip
    return nil if out.empty?
    lines = out.split("\n", -1)
    truncated = lines.size > CONTEXT_MAX_LINES
    text = lines.first(CONTEXT_MAX_LINES).join("\n")
    text += "\n\n(truncated to #{CONTEXT_MAX_LINES} lines)" if truncated
    "\n\nWorking tree (bfs --nohidden, max #{CONTEXT_MAX_LINES} lines):\n#{text}"
  end

  def guidelines_section(always_include: false)
    raw = read_agents_files.to_s.strip
    default = default_refactor_instructions.to_s.strip
    content = if raw.empty?
                default.empty? ? '' : "Project guidelines:\n#{default}"
              else
                suffix = always_include && !default.empty? ? "\n\n#{default}" : ''
                "Project guidelines:\n#{raw}#{suffix}"
              end
    content.empty? ? '' : "\n\n#{content}"
  end

  def summary_section
    summary = @session_tracker&.get_last_agent_summary
    return nil if summary.nil? || summary.to_s.strip.empty?

    "\n\nFinal summary from previous agent run:\n#{summary.to_s.strip}"
  end

  def history_section(current_request: nil)
    history = @session_tracker&.get_session_request_history(exclude_equal: current_request) || []
    return nil if history.empty?

    width = [2, history.size.to_s.length].max
    lines = history.reverse.map.with_index(1) { |req, idx| "#{idx.to_s.rjust(width)}. #{req}" }
    "\n\nPrevious requests in this session:\n" + lines.join("\n")
  end

  def non_interactive_notice
    "\n\nIMPORTANT: This agent runs in non-interactive mode. " \
    "You must make all decisions autonomously and execute tasks directly " \
    "without requesting user input, clarification, or confirmation. " \
    "Proceed with implementation based on the available context and your best judgment."
  end

  def read_agents_files
    root = Dir.pwd
    parts = %w[AGENTS.md .cursorrules].filter_map do |name|
      path = File.join(root, name)
      next unless File.exist?(path)

      File.read(path).strip
    end
    parts.empty? ? '' : parts.join("\n\n")
  end

  def default_refactor_instructions
    path = File.expand_path('../../REFACTOR.md', __dir__)
    File.exist?(path) ? File.read(path).strip : ''
  end

  def parse_json_stream_line(line)
    return [nil] * 5 if line.nil?
    stripped = line.to_s.strip
    return [nil] * 5 if stripped.empty?

    json_obj = Oj.load(stripped)
    type = json_obj['type']
    return [nil] * 5 if %w[user system].include?(type)
    return [nil] * 5 if type == 'thinking' && (json_obj['text'].nil? || json_obj['text'].empty?)

    extract_session_id(json_obj)

    [type, extract_text_from_json(json_obj)&.to_s, json_obj['request_id'] || json_obj['stream_id'] || type,
     extract_command_from_json(json_obj),
     (extract_tool_call_info(json_obj) if %w[tool_call tool_result].include?(type))]
  rescue Oj::ParseError, JSON::ParserError
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
        return text if text && !text.to_s.strip.empty?
      elsif content.is_a?(String) && !content.to_s.strip.empty?
        return content
      end
      json_obj.dig('message', 'text') || json_obj['text']
    when 'result'
      json_obj['result']
    when 'thinking'
      text = json_obj['text']
      return nil if text.nil? || text.to_s.strip.empty?
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
          args = func_args.is_a?(String) ? Oj.load(func_args) : func_args
          return args['command'] || args['cmd'] || args['input'] if args.is_a?(Hash)
          return func_args if func_args.is_a?(String) && func_args.match?(/^[a-zA-Z0-9_\-\.\/\s]+$/)
        rescue Oj::ParseError, JSON::ParserError
          return func_args if func_args.is_a?(String) && func_args.length < 200
        end
      end
      
      input = tool_call['input']
      return input if input.is_a?(String) && input.match?(/^[a-zA-Z0-9_\-\.\/\s]+$/) && input.length < 200
      return tool_call['command'] if tool_call['command']
    end

    # Only parse command from free text when this line is a tool event; avoid treating
    # assistant/prompt text (e.g. "Running: run") as a shell command.
    return nil unless %w[tool_call tool_result].include?(json_obj['type'])

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
        cmd = match[1].to_s.strip
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

    tool_info = {
      name: func_name,
      arguments: parse_tool_args(extract_tool_args(tool_call, json_obj)),
      subtype: json_obj['subtype'],
      result: json_obj['result'] || json_obj['content']
    }
    @tools_used << tool_info.dup unless @tools_used.any? { |t|
      t[:name] == func_name && t[:subtype] == tool_info[:subtype]
    }

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

    Oj.load(func_args)
  rescue Oj::ParseError, JSON::ParserError
    func_args
  end

  def tool_command_completed?(tool)
    tool[:name]&.match?(/^(run|execute|command)/i) &&
      tool[:subtype] == 'completed' &&
      tool[:result].to_s.strip != ''
  end

  def looks_like_command?(cmd)
    cmd = cmd.to_s
    return false if cmd.length < 4 || cmd.length > 500
    return false unless cmd.match?(/^[a-zA-Z0-9_\-\.\/\s\:\;\,\|\&\<\>\(\)\"\']+$/)
    # Reject single-word fragments that are not paths or flags (e.g. "run", "and a")
    return false if cmd.to_s.strip !~ /\s/ && !cmd.include?('/') && !cmd.match?(/^\-+\w/)

    cmd.match?(/\b(rspec|rake|make|npm|yarn|bundle|ruby|python|node|go| cargo|test|spec|build|run)\b/i) ||
      cmd.match?(/[\/\-]/) ||
      cmd.match?(/^[a-z]+\s+[a-z]/i)
  end

  def build_command(model:, plan_mode: false)
    cmd = %w[
      agent
      --print
      --output-format
      stream-json
      --force
    ]
    cmd << '--plan' if plan_mode
    cmd.concat(['--resume', @agent_session_id]) if @agent_session_id && !@verification_mode
    cmd.concat(['--model', model])
    cmd
  end

  # Run agent --model auto -- /compact to reduce context when resuming; skips if auto or no session.
  def run_compact_pass_if_needed(model)
    return unless @agent_session_id && model != 'auto'
    return if @compact_pass_run && !@model_call_finished_since_compact

    @display.puts 'Compacting context (model auto)...'.light_black
    cmd = build_command(model: 'auto', plan_mode: false) + ['--', '/compact']
    Timeout.timeout(120) do
      Open3.popen2e(*cmd) do |stdin, stdout_stderr, wait_thr|
        stdin.close
        stdout_stderr.read
        wait_thr.value
      end
    end
    @compact_pass_run = true
    @model_call_finished_since_compact = false
  rescue Timeout::Error
    @display.puts 'Compact pass timed out; continuing with main run.'.yellow
  end

  def clear_full_prompt_buffer
    @full_prompt_buffer = nil
  end

  def print_full_prompt(prompt, new_session: false)
    return unless @show_prompt

    if new_session
      @full_prompt_buffer = prompt.to_s
      return
    end
    @display.puts '--- Full prompt ---'.light_black
    @display.output_raw(prompt.to_s)
    @display.puts '--- End prompt ---'.light_black
  end

  def emit_full_prompt_to_display
    return if @full_prompt_buffer.to_s.strip.empty?

    @display.puts '--- Full prompt ---'.light_black
    @display.output_raw(@full_prompt_buffer.to_s)
    @display.puts '--- End prompt ---'.light_black
  end

  def display_command(cmd, prompt, new_session: false, defer_full_prompt: false)
    if defer_full_prompt && @show_prompt && !prompt.to_s.strip.empty?
      @full_prompt_buffer = prompt.to_s
    else
      print_full_prompt(prompt, new_session: new_session)
      @full_prompt_buffer = nil if new_session
    end
    @display.puts "Running: #{cmd.join(' ')}".green
    excerpt_str = format_prompt_excerpt(prompt)
    @display.output_raw(excerpt_str) if excerpt_str
  end

  def format_prompt_excerpt(prompt)
    lines = prompt_excerpt_lines(prompt)
    return nil if lines.empty?

    lines.map { |l| "  #{l}" }.join("\n") + "\n"
  end

  # First 5 lines of prompt, each line truncated to 72 chars; newlines preserved for readability.
  def prompt_excerpt_lines(prompt)
    stripped = prompt.to_s.strip
    return [] if stripped.empty?

    lines = stripped.lines.first(5).map(&:chomp)
    suffix = stripped.lines.size > 5 ? ['...'] : []
    lines.map { |l| l.size > 72 ? "#{l[0..68]}..." : l } + suffix
  end

  RECOVERABLE_NETWORK_RETRIES = 5 # 1 initial + 5 retries = 6 total attempts

  def retryable_error?(output)
    return false if output.to_s.empty?

    output.match?(/CANCEL|canceled|stream closed|0x8|http\/2 stream closed|Connection stalled/i)
  end

  def stream_json_init?(output)
    s = output.to_s.strip
    return false if s.empty?
    return true if s.start_with?('{') && s.include?('"type"') && s.include?('"system"')

    false
  end

  UNRECOVERABLE_PHRASES = %w[503 502 404].freeze
  UNRECOVERABLE_MODEL_PHRASES = %w[not found not available unavailable invalid].freeze

  def unrecoverable_error?(output)
    return false if output.to_s.empty?

    n = output.to_s.downcase
    UNRECOVERABLE_PHRASES.any? { |p| n.include?(p) } ||
      (n.include?('rate limit') && n.include?('exceeded')) ||
      n.include?('cannot use this model') ||
      (n.include?('model') && UNRECOVERABLE_MODEL_PHRASES.any? { |p| n.include?(p) }) ||
      n.include?('usage limit') ||
      n.include?('this error is unrecoverable')
  end

  def usage_unrecoverable?(output)
    return false if output.to_s.empty?

    n = output.to_s.downcase
    (n.include?('rate limit') && n.include?('exceeded')) ||
      n.include?('usage limit') ||
      n.include?('this error is unrecoverable')
  end

  def run_with_timeout_monitoring(model, wrapped, new_session: false,
                                  prompt_request_reader: nil, on_prompt_request: nil,
                                  queue_wakeup_reader: nil, defer_full_prompt: false)
    @tools_used = []
    @passthrough = test_runner_running?
    return run_without_timeout(model, wrapped, new_session: new_session) if @passthrough

    @state_mutex.synchronize do
      @state = { detected: false, complete: false, pid: nil, disabled: false, timed_out: false, last_chunk: nil,
                 start: nil, abort_for_queue: false }
    end
    monitor_thread = start_monitor_thread
    timeout_thread = start_timeout_thread

    begin
      execute_agent_process(model, wrapped, new_session: new_session,
                            prompt_request_reader: prompt_request_reader, on_prompt_request: on_prompt_request,
                            queue_wakeup_reader: queue_wakeup_reader, defer_full_prompt: defer_full_prompt)
    ensure
      @state_mutex.synchronize { @state[:complete] = true }
      monitor_thread&.kill
      timeout_thread&.kill
    end
  end

  def run_plan_mode(model, p, new_session: false)
    clear_full_prompt_buffer if new_session
    @tools_used = []
    wrapped = wrap_prompt(p, new_session: new_session, current_request: p)
    run_compact_pass_if_needed(model)
    cmd = setup_subprocess_run(model, wrapped, plan_mode: true, new_session: new_session)

    begin
      out = Open3.popen2e(*cmd) do |stdin, stdout_stderr, wait_thr|
        @state_mutex.synchronize { @state = { timed_out: false } }
        stdin.write(wrapped)
        stdin.close
        result = process_agent_output(stdout_stderr, wait_thr)
        [result[2].success?, result[0]]
      end
      @model_call_finished_since_compact = true
      out
    rescue StandardError => e
      @display.puts "❌ Agent execution error: #{e.message}".red
      [false, "Execution error: #{e.message}"]
    end
  end

  def run(model, p, base_delay: 1, verification_mode: false, new_session: false,
          prompt_request_reader: nil, on_prompt_request: nil, current_request: nil,
          queue_wakeup_reader: nil, defer_full_prompt: false)
    @verification_mode = verification_mode
    clear_full_prompt_buffer if new_session
    wrapped = wrap_prompt(p, new_session: new_session, current_request: current_request || p)
    run_compact_pass_if_needed(model)
    retries = 0
    loop do
      stdout, _, status, timeout_reason = run_with_timeout_monitoring(model, wrapped,
        new_session: new_session,
        prompt_request_reader: prompt_request_reader, on_prompt_request: on_prompt_request,
        queue_wakeup_reader: queue_wakeup_reader, defer_full_prompt: defer_full_prompt)
      @model_call_finished_since_compact = true
      return [false, '', :abort_for_queue] if timeout_reason == :abort_for_queue

      output = (stdout || '').to_s
      if output.to_s.strip.empty?
        # Empty response is retryable; do not return success
      elsif verification_mode && (
        stream_json_init?(output) || retryable_error?(output) || output.include?('Timeout after')
      )
        # Treat as failure so verifier retries; do not return success
      elsif status&.success?
        return [true, output, nil]
      elsif verification_mode && output.to_s.strip.length > 0
        return [true, output, nil]
      end

      reason = if output.to_s.strip.empty?
                 :recoverable
               elsif timeout_reason == :no_data
                 :recoverable
               elsif (status.nil? || !status.success?) && stdout.nil?
                 :recoverable
               elsif stream_json_init?(output)
                 :recoverable
               elsif unrecoverable_error?(output)
                 :unrecoverable
               elsif retryable_error?(output) || output.include?('Timeout after')
                 :recoverable
               end

      if reason == :recoverable && retries < RECOVERABLE_NETWORK_RETRIES
        retries += 1
        delay = base_delay * (2**(retries - 1))
        @display.puts "⚠️  Network error, retrying in #{delay}s... (#{retries}/#{RECOVERABLE_NETWORK_RETRIES})".yellow
        sleep(delay)
        next
      end
      return [false, output.to_s, reason]
    end
  rescue StandardError => e
    @display.puts "❌ Agent execution error: #{e.message}".red
    [false, "Execution error: #{e.message}", :unrecoverable]
  end

  def run_without_timeout(model, wrapped, new_session: false)
    @tools_used = []
    cmd = setup_subprocess_run(model, wrapped, new_session: new_session)
    begin
      Open3.popen2e(*cmd) do |stdin, stdout_stderr, wait_thr|
        @state_mutex.synchronize { @state = { timed_out: false } }
        stdin.write(wrapped)
        stdin.close
        process_agent_output(stdout_stderr, wait_thr)
      end
    rescue StandardError => e
      @display.puts "❌ Agent execution error: #{e.message}".red
      [nil, nil, Struct.new(:success?).new(false)]
    end
  end

  def process_json_stream_line(line, final)
    type, text, stream_id, command, tool = parse_json_stream_line(line.to_s.strip)
    unless @passthrough
      if tool
        @display.display_tool_call(tool)
        if tool[:name] == 'ask' && tool[:subtype] == 'completed'
          @display.puts "Ask output:".cyan
          tool[:result].to_s.each_line { |l| @display.puts "  #{l.chomp}".light_black }
        elsif tool_command_completed?(tool)
          @display.puts "Command output:".cyan
          tool[:result].to_s.each_line { |l| @display.puts "  #{l.chomp}".light_black }
        end
      end
      @display.puts "Running: #{command}".green if command && !command.empty?
    end
    return final unless text && !text.empty?

    case type
    when 'result'
      text
    when 'thinking'
      @display.print_thinking_indicator unless @passthrough
      final
    when 'assistant', nil
      @display.print_word(text, stream_id: stream_id) unless @passthrough
      final
    else
      final
    end
  end

  private

  def drain_prompt_pipe(pipe)
    return unless pipe

    loop do
      ready = IO.select([pipe], nil, nil, 0)
      break unless ready && ready[0].include?(pipe)

      pipe.read(1024) rescue break
    end
  end

  def start_monitor_thread
    Thread.new do
      loop do
        sleep TEST_RUNNER_CHECK_INTERVAL
        complete = @state_mutex.synchronize { @state[:complete] }
        break if complete
        pid = @state_mutex.synchronize { @state[:pid] }
        next unless pid
        detected = @state_mutex.synchronize { @state[:detected] }
        next if detected
        next unless test_runner_running?(pid)
        @state_mutex.synchronize { @state[:detected] = @state[:disabled] = true }
        @display.puts '⚠️  Test runner detected (child of agent), disabling timeout'.yellow
      end
    end
  end

  def start_timeout_thread
    Thread.new do
      loop do
        sleep TEST_RUNNER_CHECK_INTERVAL
        complete, disabled, pid = @state_mutex.synchronize do
          [@state[:complete], @state[:disabled], @state[:pid]]
        end
        break if complete
        next if disabled || (pid && test_runner_running?(pid))
        check_timeouts
      end
    end
  end

  def check_timeouts
    now = Time.now
    reason = @state_mutex.synchronize do
      if @state[:start] && (now - @state[:start]) >= MAX_EXECUTION_TIMEOUT
        @state[:timeout_reason] = :max_time
        "maximum execution time (#{MAX_EXECUTION_TIMEOUT}s)"
      elsif @state[:last_chunk] && (now - @state[:last_chunk]) >= EXECUTION_TIMEOUT
        @state[:timeout_reason] = :no_data
        "no data received (#{EXECUTION_TIMEOUT}s)"
      end
    end
    terminate_agent(reason) if reason
  end

  def terminate_agent(reason)
    pid, complete = @state_mutex.synchronize do
      @state[:timed_out] = true
      [@state[:pid], @state[:complete]]
    end
    @display.puts "❌ Agent timed out after #{reason}".red
    return unless pid
    begin
      Process.kill('TERM', pid)
      sleep 2
      Process.kill('KILL', pid) unless complete
    rescue Errno::ESRCH
      # Process already exited
    end
  end

  def execute_agent_process(model, wrapped, new_session: false,
                            prompt_request_reader: nil, on_prompt_request: nil,
                            queue_wakeup_reader: nil, defer_full_prompt: false)
    cmd = setup_subprocess_run(model, wrapped, new_session: new_session, defer_full_prompt: defer_full_prompt)
    Open3.popen2e(*cmd) do |stdin, stdout_stderr, wait_thr|
      now = Time.now
      @state_mutex.synchronize do
        @state[:pid] = wait_thr.pid
        @state[:start] = @state[:last_chunk] = now
      end
      stdin.write(wrapped)
      stdin.close
      process_agent_output(stdout_stderr, wait_thr,
                          prompt_request_reader: prompt_request_reader, on_prompt_request: on_prompt_request,
                          queue_wakeup_reader: queue_wakeup_reader)
    end
  end

  def setup_subprocess_run(model, wrapped, plan_mode: false, new_session: false, defer_full_prompt: false)
    @passthrough = false
    @display.reset_stream_tracking unless @passthrough
    cmd = build_command(model: model, plan_mode: plan_mode)
    display_command(cmd, wrapped, new_session: new_session, defer_full_prompt: defer_full_prompt) unless @passthrough
    cmd
  end

  def process_agent_output(stdout_stderr, wait_thr, prompt_request_reader: nil, on_prompt_request: nil,
                           queue_wakeup_reader: nil)
    raw, final, buffer = '', '', ''
    drain_prompt_pipe(prompt_request_reader) if prompt_request_reader && on_prompt_request
    read_ios = [stdout_stderr]
    read_ios << prompt_request_reader if prompt_request_reader && on_prompt_request
    read_ios << queue_wakeup_reader if queue_wakeup_reader
    loop do
      break_out = @state_mutex.synchronize { @state[:timed_out] || @state[:abort_for_queue] }
      break if break_out
      ready = IO.select(read_ios, nil, nil, 0.5)
      if queue_wakeup_reader && ready && ready[0].include?(queue_wakeup_reader)
        queue_wakeup_reader.read(1024) rescue nil
        @state_mutex.synchronize { @state[:abort_for_queue] = true }
        break
      end
      if prompt_request_reader && ready && ready[0].include?(prompt_request_reader)
        skip = @state_mutex.synchronize { @state[:start] && (Time.now - @state[:start]) < 0.5 }
        next if skip
        data = prompt_request_reader.read(1024) rescue nil
        if data.nil? || data.empty?
          read_ios.delete(prompt_request_reader)
          next
        end
        on_prompt_request.call
        drain_prompt_pipe(prompt_request_reader)
        next
      end
      if ready && ready[0].include?(stdout_stderr)
        begin
          chunk = stdout_stderr.readpartial(4096)
          @state_mutex.synchronize { @state[:last_chunk] = Time.now }
          raw += chunk
          buffer += chunk
          buffer, final = process_buffer(buffer, final)
        rescue EOFError then break
        end
        next
      end
      next if ready
      if !wait_thr.alive?
        raw, final, buffer = process_remaining_output(stdout_stderr, raw, final, buffer)
        break
      end
    end
    finalize_execution(raw, final, wait_thr)
  end

  def process_remaining_output(stdout_stderr, raw, final, buffer)
    remaining = stdout_stderr.read rescue nil
    return [raw, final, buffer] unless remaining

    raw += remaining
    buffer += remaining
    buffer, final = process_buffer(buffer, final)
    [raw, final, buffer]
  end

  def process_buffer(buffer, final)
    while (idx = buffer.index("\n"))
      line_with_newline = buffer[0..idx]
      line = line_with_newline.to_s.strip
      buffer = buffer[(idx + 1)..-1] || ''
      $stdout.write(line_with_newline) && $stdout.flush if @passthrough
      final = process_json_stream_line(line, final)
    end
    [buffer, final]
  end

  def finalize_execution(raw, final, wait_thr)
    abort_for_queue, timed_out, timeout_reason = @state_mutex.synchronize do
      [@state && @state[:abort_for_queue], @state && @state[:timed_out], @state&.dig(:timeout_reason)]
    end
    if abort_for_queue
      terminate_agent("queued request(s) added by another instance")
      return [raw.to_s, '', Struct.new(:success?).new(false), :abort_for_queue]
    end
    status = wait_thr.value rescue Struct.new(:success?).new(false)
    status = Struct.new(:success?).new(false) if timed_out
    out = (final.respond_to?(:empty?) && final.empty?) ? raw : final
    out = out.to_s
    success_for_display = status.success? || (@verification_mode && out.to_s.strip.length > 0)
    unless @passthrough
      @display.flush_word_buffer
      display_tools_summary
      @display.display_agent_call_result(success_for_display, @tools_used.size)
    end
    [out, '', status, timeout_reason]
  end

  def display_tools_summary
    return if @tools_used.empty?

    @display.out_puts ''
    @display.puts "Tools applied (#{@tools_used.size}):".cyan
    @tools_used.each do |tool|
      args_str = @display.format_tool_call_args(tool[:arguments])
      display_text = args_str ? "  • #{tool[:name]}(#{args_str})" : "  • #{tool[:name]}"
      @display.out_puts display_text.colorize(:light_blue)
    end
    @display.out_puts ''
  end
end
