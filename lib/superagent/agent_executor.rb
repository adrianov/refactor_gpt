# frozen_string_literal: true

require 'open3'
require 'json'
require 'oj'
require 'rbconfig'
require 'timeout'

# Handles agent command execution with retry logic.
# rubocop:disable Metrics/ClassLength -- slightly over after extracting SameToolErrorTracker for unit testability
class AgentExecutor
  EXECUTION_TIMEOUT = 60
  MAX_EXECUTION_TIMEOUT = 600
  TEST_RUNNER_CHECK_INTERVAL = 2

  def initialize(display, session_tracker: nil, show_full_prompt: true)
    @display = display
    @tools_used = []
    @same_tool_error_tracker = SameToolErrorTracker.new
    @session_tracker = session_tracker
    @prompt_builder = AgentPromptBuilder.new(session_tracker)
    @stream_parser = JsonStreamParser.new
    @stream_line_parser = StreamLineParser.new(json_parser: @stream_parser)
    @assistant_accumulator = AssistantTextAccumulator.new
    @state_mutex = Mutex.new
    @full_prompt_buffer = nil
    @show_full_prompt = show_full_prompt
    @verification_mode = false
  end

  def show_full_prompt?
    @show_full_prompt
  end

  def test_runner_running?(pid = nil)
    TestRunnerDetector.test_runner_running?(pid)
  end

  def long_build_running?(pid)
    LongBuildDetector.long_build_running?(pid)
  end

  def usage_unrecoverable?(output)
    RunFailureClassifier.usage_unrecoverable?(output)
  end

  def wrap_prompt(p, new_session: false, current_request: nil, continuation_analysis: nil, fix_stage: false)
    @prompt_builder.wrap_prompt(
      p,
      new_session: new_session,
      current_request: current_request,
      verification_mode: @verification_mode,
      continuation_analysis: continuation_analysis,
      fix_stage: fix_stage
    )
  end

  def non_interactive_notice
    @prompt_builder.non_interactive_notice
  end

  def guidelines_section(always_include: false)
    @prompt_builder.guidelines_section(always_include: always_include)
  end

  def tool_command_completed?(tool)
    tool[:name]&.match?(/^(run|execute|command)/i) &&
      tool[:subtype] == 'completed' &&
      (tool[:result] && !tool[:result].to_s.strip.empty?)
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
    cmd.concat(['--model', model])
    cmd
  end

  def clear_full_prompt_buffer
    @full_prompt_buffer = nil
  end

  def print_full_prompt(prompt, new_session: false)
    return unless show_full_prompt? && (prompt && !prompt.to_s.strip.empty?)

    @full_prompt_buffer = prompt.to_s if new_session
    @display.puts '--- Full prompt ---'.light_black
    @display.output_raw(prompt.to_s)
    @display.puts '--- End prompt ---'.light_black
  end

  def emit_full_prompt_to_display
    return unless show_full_prompt? && (@full_prompt_buffer && !@full_prompt_buffer.to_s.strip.empty?)

    @display.puts '--- Full prompt ---'.light_black
    @display.output_raw(@full_prompt_buffer.to_s)
    @display.puts '--- End prompt ---'.light_black
  end

  def display_command(cmd, prompt, new_session: false, defer_full_prompt: false)
    if defer_full_prompt && show_full_prompt? && (prompt && !prompt.to_s.strip.empty?)
      @full_prompt_buffer = prompt.to_s
    else
      print_full_prompt(prompt, new_session: new_session)
      @full_prompt_buffer = nil unless new_session
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

  MAX_RECOVERABLE_RETRIES = 5 # timeout and network errors: 1 initial + up to 5 retries

  def run_with_timeout_monitoring(model, wrapped, new_session: false,
                                  prompt_request_reader: nil, on_prompt_request: nil,
                                  defer_full_prompt: false)
    reset_run_tool_state
    @passthrough = test_runner_running?
    return run_without_timeout(model, wrapped, new_session: new_session) if @passthrough

    @state_mutex.synchronize do
      @state = { detected: false, complete: false, pid: nil, disabled: false, timed_out: false, last_chunk: nil,
                 start: nil, queue_prompt_active: false }
    end
    monitor_thread = start_monitor_thread
    timeout_thread = start_timeout_thread

    begin
      execute_agent_process(model, wrapped, new_session: new_session,
                            prompt_request_reader: prompt_request_reader, on_prompt_request: on_prompt_request,
                            defer_full_prompt: defer_full_prompt)
    ensure
      @state_mutex.synchronize { @state[:complete] = true }
      monitor_thread&.kill
      timeout_thread&.kill
    end
  end

  def run_plan_mode(model, p, new_session: false, continuation_analysis: nil)
    clear_full_prompt_buffer if new_session
    reset_run_tool_state
    wrapped = PromptCompactor.compact(
      wrap_prompt(p, new_session: new_session, current_request: p, continuation_analysis: continuation_analysis)
    )
    cmd = setup_subprocess_run(model, wrapped, plan_mode: true, new_session: new_session)
    run_plan_subprocess(cmd, wrapped)
  rescue StandardError => e
    @display.puts "❌ Agent execution error: #{e.message}".red
    [false, "Execution error: #{e.message}"]
  end

  def run(model, p, base_delay: 1, verification_mode: false, new_session: false,
          prompt_request_reader: nil, on_prompt_request: nil, current_request: nil,
          defer_full_prompt: false, continuation_analysis: nil, fix_stage: false)
    @verification_mode = verification_mode
    clear_full_prompt_buffer if new_session
    wrapped = PromptCompactor.compact(
      wrap_prompt(p, new_session: new_session, current_request: current_request || p,
                  continuation_analysis: continuation_analysis, fix_stage: fix_stage)
    )
    retries = 0
    loop do
      result = run_one_attempt(model, wrapped, retries, base_delay,
        prompt_request_reader: prompt_request_reader, on_prompt_request: on_prompt_request,
        new_session: new_session, defer_full_prompt: defer_full_prompt)
      return result[:tuple] if result[:done]

      retries = result[:retries]
    end
  rescue StandardError => e
    @display.puts "❌ Agent execution error: #{e.message}".red
    [false, "Execution error: #{e.message}", :unrecoverable]
  end

  def run_one_attempt(model, wrapped, retries, base_delay,
                      prompt_request_reader:, on_prompt_request:, new_session:, defer_full_prompt:)
    stdout, _, status, timeout_reason = run_with_timeout_monitoring(model, wrapped,
      new_session: new_session,
      prompt_request_reader: prompt_request_reader, on_prompt_request: on_prompt_request,
      defer_full_prompt: defer_full_prompt)
    output = (stdout || '').to_s
    return { done: true, tuple: run_success_tuple(output, status) } if run_success?(output, status)

    reason = RunFailureClassifier.failure_reason(output, status, stdout, timeout_reason)
    can_retry = reason == :recoverable && retries < MAX_RECOVERABLE_RETRIES
    unless can_retry
      return { done: true, tuple: [false, output.to_s, reason == :recoverable ? :max_retries_exceeded : reason] }
    end

    { done: false, retries: run_retry_recoverable(retries, base_delay) }
  end

  def run_without_timeout(model, wrapped, new_session: false)
    reset_run_tool_state
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

  # Processes one full stream line from the agent output.
  def process_stream_line(line, final)
    parsed = @stream_line_parser.parse_stream_line(line)
    capture_last_result_for_recap(parsed)
    record_tool_outcome(parsed[:tool]) if parsed[:tool]
    display_tool_and_command(parsed[:tool], parsed[:command]) unless @passthrough
    @full_agent_output = @assistant_accumulator.accumulate(parsed, @full_agent_output)
    content = display_content_for(parsed)
    return final unless content && !content.empty?

    handle_stream_line_display(content, parsed, final)
  end

  def finalize_display(success_for_display)
    @display.flush_assistant_text_buffer
    display_tools_summary
    @display.display_agent_call_result(success_for_display, @tools_used.size)
  end

  def last_recap_result
    @last_result_for_recap
  end

  private

  def run_success?(output, status)
    return false if output.nil? || output.to_s.strip.empty?
    return false if verification_retry_condition?(output)

    status&.success? || (@verification_mode && (output && !output.to_s.strip.empty?))
  end

  def verification_retry_condition?(output)
    @verification_mode && (
      RunFailureClassifier.stream_json_init?(output) ||
      RunFailureClassifier.retryable_error?(output) ||
      output.include?('Timeout after')
    )
  end

  def run_success_tuple(output, status)
    return nil unless run_success?(output, status)

    [true, output, nil]
  end

  def display_content_for(parsed)
    parsed[:type].to_s == 'result' ? parsed[:result] : parsed[:text]
  end

  # Session recap uses type=result and the :result field only, not :text.
  def capture_last_result_for_recap(parsed)
    @last_result_for_recap = parsed[:result] if parsed[:type].to_s == 'result' && parsed[:result]
  end

  def record_tool_outcome(tool)
    record_tool_used(tool)
    on_tool_completed(tool) if (tool[:subtype] || tool['subtype']).to_s == 'completed'
  end

  def reset_run_tool_state
    @tools_used = []
    @same_tool_error_tracker.reset
  end

  # Interrupt when same tool + same params fails 3 times in a row.
  # Skip tracking when key has no arguments (stream may omit args on completed calls; would collapse all into one key).
  def on_tool_completed(tool)
    key = ToolOutcome.invocation_key(tool)
    return if key.nil? || @state_mutex.synchronize { @state[:timed_out] }
    return if key.split("\0", 2)[1].to_s.strip.empty?
    return unless @same_tool_error_tracker.record(key, error: ToolOutcome.tool_result_error?(tool)) == :interrupt

    terminate_agent('same tool and parameters failed 3 times', cause: :interrupt)
  end

  def record_tool_used(tool)
    return if @tools_used.any? { |t| t[:name] == tool[:name] && t[:subtype] == tool[:subtype] }

    @tools_used << tool.dup
  end

  def display_tool_result(tool)
    display_ask_result(tool) if tool[:name] == 'ask' && tool[:subtype] == 'completed'
    display_command_result(tool) if tool_command_completed?(tool)
  end

  def display_ask_result(tool)
    @display.puts "Ask output:".cyan
    tool[:result].to_s.each_line { |l| @display.puts "  #{l.chomp}".light_black }
  end

  def display_command_result(tool)
    @display.puts "Command output:".cyan
    tool[:result].to_s.each_line { |l| @display.puts "  #{l.chomp}".light_black }
  end

  def run_plan_subprocess(cmd, wrapped)
    Open3.popen2e(*cmd) do |stdin, stdout_stderr, wait_thr|
      @state_mutex.synchronize { @state = { timed_out: false } }
      stdin.write(wrapped)
      stdin.close
      result = process_agent_output(stdout_stderr, wait_thr)
      [result[2].success?, result[0]]
    end
  end

  def run_retry_recoverable(retries, base_delay)
    retries += 1
    delay = base_delay * (2**(retries - 1))
    @display.puts "⚠️  Recoverable error (timeout or network), retrying in #{delay}s... " \
                  "(#{retries}/#{MAX_RECOVERABLE_RETRIES})".yellow
    sleep(delay)
    retries
  end

  def compute_timeout_reason
    now = Time.now
    @state_mutex.synchronize do
      if @state[:start] && (now - @state[:start]) >= MAX_EXECUTION_TIMEOUT
        @state[:timeout_reason] = :max_time
        return "maximum execution time (#{MAX_EXECUTION_TIMEOUT}s)"
      end
      if !@state[:queue_prompt_active] && @state[:last_chunk] && (now - @state[:last_chunk]) >= EXECUTION_TIMEOUT
        @state[:timeout_reason] = :no_data
        return "no data received (#{EXECUTION_TIMEOUT}s)"
      end
    end
    nil
  end

  def handle_prompt_request_read(prompt_request_reader, on_prompt_request, read_ios)
    data = prompt_request_reader.read(1024) rescue nil
    if data.nil?
      read_ios.delete(prompt_request_reader)
      return read_ios
    end
    return read_ios if data.empty?

    on_prompt_request.call
    drain_prompt_pipe(prompt_request_reader)
    read_ios
  end

  def read_stdout_chunk(stdout_stderr, raw, final, buffer)
    chunk = stdout_stderr.readpartial(4096)
    @state_mutex.synchronize { @state[:last_chunk] = Time.now }
    raw += chunk
    buffer += chunk
    buffer, final = process_buffer(buffer, final)
    [raw, final, buffer]
  end

  def display_tool_and_command(tool, command)
    return unless tool

    @display.display_tool_call(tool)
    display_tool_result(tool)
    @display.puts "Running: #{command}".green if command && !command.empty?
  end

  def handle_stream_line_display(content, parsed, _final)
    @display.apply_stream_line_display(
      parsed[:type], content, parsed[:stream_id],
      think_close_only: parsed[:think_close_only],
      trailing_think_close: parsed[:trailing_think_close],
      passthrough: @passthrough
    )
  end

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
        message = timeout_exemption_message(pid)
        next unless message

        @state_mutex.synchronize { @state[:detected] = @state[:disabled] = true }
        @display.puts message.yellow
      end
    end
  end

  def timeout_exemption_message(pid)
    if test_runner_running?(pid)
      name = TestRunnerDetector.matched_runner_name(pid)
      return "⚠️  Test runner detected (#{name}), disabling timeout"
    end
    if long_build_running?(pid)
      name = LongBuildDetector.matched_build_name(pid)
      return "⚠️  Long build detected (#{name}), disabling timeout"
    end

    nil
  end

  def start_timeout_thread
    Thread.new do
      loop do
        sleep TEST_RUNNER_CHECK_INTERVAL
        complete, disabled, pid = @state_mutex.synchronize do
          [@state[:complete], @state[:disabled], @state[:pid]]
        end
        break if complete
        next if disabled || (pid && (test_runner_running?(pid) || long_build_running?(pid)))
        check_timeouts
      end
    end
  end

  def check_timeouts
    return if @state_mutex.synchronize { @state[:timed_out] }

    reason = compute_timeout_reason
    terminate_agent(reason, cause: :timeout) if reason
  end

  def terminate_agent(reason, cause: :timeout)
    pid, complete = @state_mutex.synchronize do
      @state[:timed_out] = true
      [@state[:pid], @state[:complete]]
    end
    message = cause == :timeout ? "Agent timed out after #{reason}" : "Agent interrupted: #{reason}"
    @display.puts "❌ #{message}".red
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
                            defer_full_prompt: false)
    cmd = setup_subprocess_run(model, wrapped, new_session: new_session, defer_full_prompt: defer_full_prompt)
    Open3.popen2e(*cmd) do |stdin, stdout_stderr, wait_thr|
      now = Time.now
      @state_mutex.synchronize do
        @state[:pid] = wait_thr.pid
        @state[:start] = @state[:last_chunk] = now
      end
      stdin.write(wrapped)
      stdin.close
      if prompt_request_reader && on_prompt_request
        run_agent_with_interactive_queue(stdout_stderr, wait_thr,
          prompt_request_reader: prompt_request_reader, on_prompt_request: on_prompt_request)
      else
        process_agent_output(stdout_stderr, wait_thr,
                            prompt_request_reader: nil, on_prompt_request: nil)
      end
    end
  end

  # Reader thread keeps processing agent output (updating last_chunk) while main thread runs Reline.
  # Regression: calling on_prompt_request in the read loop blocked reading and caused 60s timeout.
  def run_agent_with_interactive_queue(stdout_stderr, wait_thr, prompt_request_reader:, on_prompt_request:)
    prompt_req_r, prompt_req_w = IO.pipe
    reader_callback = proc { prompt_req_w.write('x') rescue nil }
    result = nil
    reader_thr = Thread.new do
      result = process_agent_output(stdout_stderr, wait_thr,
        prompt_request_reader: prompt_request_reader, on_prompt_request: reader_callback)
    end
    wait_for_prompt_requests(reader_thr, prompt_req_r, on_prompt_request)
    prompt_req_w.close rescue nil
    reader_thr.join
    prompt_req_r.close rescue nil
    result
  end

  def wait_for_prompt_requests(reader_thr, prompt_req_r, on_prompt_request)
    while reader_thr.alive?
      ready = IO.select([prompt_req_r], nil, nil, 0.5)
      next unless ready && ready[0].include?(prompt_req_r)
      prompt_req_r.read(1024) rescue nil
      @state_mutex.synchronize { @state[:queue_prompt_active] = true }
      begin
        on_prompt_request.call
      ensure
        @state_mutex.synchronize { @state[:queue_prompt_active] = false }
      end
    end
  end

  def setup_subprocess_run(model, wrapped, plan_mode: false, new_session: false, defer_full_prompt: false)
    @passthrough = false
    @display.reset_stream_tracking unless @passthrough
    cmd = build_command(model: model, plan_mode: plan_mode)
    display_command(cmd, wrapped, new_session: new_session, defer_full_prompt: defer_full_prompt) unless @passthrough
    cmd
  end

  def process_agent_output(stdout_stderr, wait_thr, prompt_request_reader: nil, on_prompt_request: nil)
    @full_agent_output = ''
    @last_result_for_recap = nil
    raw, final, buffer = '', '', ''
    drain_prompt_pipe(prompt_request_reader) if prompt_request_reader && on_prompt_request
    read_ios = [stdout_stderr]
    read_ios << prompt_request_reader if prompt_request_reader && on_prompt_request
    loop do
      break if @state_mutex.synchronize { @state[:timed_out] }
      ready = IO.select(read_ios, nil, nil, 0.5)
      action = output_ready_action(ready, read_ios, prompt_request_reader, stdout_stderr, wait_thr)
      raw, final, buffer, read_ios, done = process_output_action(
        action, stdout_stderr, raw, final, buffer, read_ios,
        prompt_request_reader, on_prompt_request, wait_thr
      )
      break if done
    end
    finalize_execution(raw, final, wait_thr)
  end

  def output_ready_action(ready, _read_ios, prompt_request_reader, stdout_stderr, wait_thr)
    ready_read = ready && ready[0]
    return :prompt if prompt_request_reader && ready_read && ready_read.include?(prompt_request_reader)
    return :stdout if ready_read && ready_read.include?(stdout_stderr)
    return :eof if !ready && !wait_thr.alive?

    nil
  end

  def process_output_action(action, stdout_stderr, raw, final, buffer, read_ios,
                            prompt_request_reader, on_prompt_request, _wait_thr)
    case action
    when :prompt
      read_ios = handle_prompt_request_read(prompt_request_reader, on_prompt_request, read_ios)
      [raw, final, buffer, read_ios, false]
    when :stdout
      raw, final, buffer = read_stdout_chunk(stdout_stderr, raw, final, buffer)
      [raw, final, buffer, read_ios, false]
    when :eof
      raw, final, buffer = process_remaining_output(stdout_stderr, raw, final, buffer)
      [raw, final, buffer, read_ios, true]
    else
      [raw, final, buffer, read_ios, false]
    end
  rescue EOFError
    [raw, final, buffer, read_ios, true]
  end

  def process_remaining_output(stdout_stderr, raw, final, buffer)
    remaining = stdout_stderr.read rescue nil
    return [raw, final, buffer] unless remaining

    raw += remaining
    buffer += remaining
    buffer, final = process_buffer(buffer, final, flush_remaining: true)
    [raw, final, buffer]
  end

  def process_buffer(buffer, final, flush_remaining: false)
    sep = JsonStreamParser::LINE_SEP
    while (idx = buffer.index(sep))
      line_with_sep = buffer[0..idx]
      buffer = buffer[(idx + 1)..-1] || ''
      final = process_one_jsonl_line(line_with_sep, final)
    end
    if flush_remaining && (buffer && !buffer.to_s.strip.empty?)
      line = buffer.to_s.strip
      write_passthrough_line(line + sep)
      final = process_stream_line(line, final)
      buffer = ''
    end
    [buffer, final]
  end

  def process_one_jsonl_line(line_with_sep, final)
    write_passthrough_line(line_with_sep)
    process_stream_line(line_with_sep.to_s.strip, final)
  end

  def write_passthrough_line(line)
    $stdout.write(line) && $stdout.flush if @passthrough
  end

  def finalize_execution(raw, final, wait_thr)
    timed_out, timeout_reason = finalize_execution_state
    status = finalize_execution_status(wait_thr, timed_out)
    out = finalize_output(raw, final)
    finalize_display(status.success? || (@verification_mode && (out && !out.to_s.strip.empty?))) unless @passthrough
    [out, '', status, timeout_reason]
  end

  def finalize_execution_state
    @state_mutex.synchronize { [@state && @state[:timed_out], @state&.dig(:timeout_reason)] }
  end

  def finalize_execution_status(wait_thr, timed_out)
    status = wait_thr.value rescue Struct.new(:success?).new(false)
    timed_out ? Struct.new(:success?).new(false) : status
  end

  def finalize_output(raw, final)
    fallback = (final.respond_to?(:empty?) && final.empty?) ? raw : final
    (@full_agent_output && !@full_agent_output.to_s.strip.empty?) ? @full_agent_output.to_s : fallback.to_s
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
# rubocop:enable Metrics/ClassLength
