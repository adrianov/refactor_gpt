# frozen_string_literal: true

require_relative "display"
require_relative "request_reader"
require_relative "agent_executor"
require_relative "verification_handler"
require_relative "session_tracker"
require_relative "pending_request_queue"
require_relative "auto_only_lock"
require_relative "../completion_notifier"
require_relative "../instance_lock"
require_relative "../../ask_gpt"

# Main orchestrator class for superagent execution
class Superagent
  NON_INTERACTIVE_NOTICE = /
    (?:^|\n)
    IMPORTANT:\s+This\s+agent\s+runs\s+in\s+non-interactive\s+mode\.
    .*?
    (?:make\s+all\s+decisions\s+autonomously|execute\s+tasks\s+directly|without\s+requesting\s+user\s+input)
    .*?
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
  MODELS_AUTO_ONLY = %w[auto auto auto].freeze

  GITIGNORE_PREPEND = 'Ensure .gitignore excludes build artifacts, dependencies, and other unneeded files and folders. '

  def initialize(
    display: Display.new,
    request_reader: nil,
    agent_executor: nil,
    verification_handler: nil,
    session_tracker: nil,
    auto_only: false,
    resume_enabled: false,
    show_prompt: false
  )
    @display = display
    @session_tracker = session_tracker || SessionTracker.new(@display)
    @request_reader = request_reader || RequestReader.new(@display)
    @agent_executor = agent_executor || AgentExecutor.new(
      @display,
      session_tracker: @session_tracker,
      show_prompt: show_prompt
    )
    @verification_handler = verification_handler || VerificationHandler.new(
      @display,
      @agent_executor,
      session_tracker: @session_tracker
    )
    @start_time = nil
    @active_elapsed = 0
    @waiting_elapsed = 0
    @active_start = nil
    @waiting_start = nil
    @current_pass = nil
    @current_model = nil
    @current_model_index = 0
    @pass_timings = []
    @feature_start_time = nil
    @session_description = nil
    @session_tags = []
    @session_continuation = false
    @current_request = nil
    @attempt_count_per_model = {}
    @pending_queue = PendingRequestQueue.new(@display)
    @session_outcomes = []
    @input_thread = nil
    @input_wakeup_writer = nil
    @auto_only = auto_only
    @resume_enabled = resume_enabled
    @git_initialized_this_run = false
  end

  def run(start_model_index: 0, request: nil, continuation_analysis: nil)
    @session_outcomes ||= []
    initialize_run(request)
    @waiting_start = Time.now if request.nil?
    raw_req = request || @request_reader.read
    raw_req = prepend_gitignore_instruction(raw_req) if request.nil? && @git_initialized_this_run
    if @waiting_start
      @waiting_elapsed += Time.now - @waiting_start
      @waiting_start = nil
    end
    @request_reader.add_to_request_history(raw_req) if request.nil? && !raw_req.to_s.strip.empty?
    model_index_from_request = extract_model_index(raw_req)
    req = sanitize_request(raw_req)
    @request_reader.validate(req)
    @current_request = req

    if continuation_analysis
      apply_continuation_analysis(continuation_analysis)
    elsif @resume_enabled
      analyze_session_continuation(req)
    end
    @agent_executor.reset_agent_session unless @session_continuation
    save_current_session(req)
    
    start_index = determine_start_index(model_index_from_request, start_model_index)
    @display.display_start_message(req, @session_continuation, @session_tags)
    update_terminal_title(@session_continuation ? '↻ Continuing session' : 'Running...')

    return run_plan_mode(req, start_index) if @request_reader.plan_mode

    @display.display_pending_hint
    start_pending_input_thread

    @feature_start_time = Time.now
    @pass_timings = []
    @active_start = Time.now
    execute_attempts(start_index, req)
    handle_final_failure unless @last_attempt_success
  end

  def run_plan_mode(req, start_index = 0)
    @active_start = Time.now
    update_terminal_title('Planning...')
    @display.puts 'Running in plan mode...'.cyan
    @display.out_puts ''

    models[start_index..-1].each_with_index do |model, relative_idx|
      idx = start_index + relative_idx
      @current_pass = idx + 1
      @current_model = model
      update_terminal_title("Planning: #{model}")
      @display.display_attempt_header(model, idx, models.size)

      success, output = @agent_executor.run_plan_mode(model, req, new_session: !@session_continuation)
      return handle_plan_success if success

      @display.display_agent_failure(output, nil)
    end

    handle_final_failure
  end

  private

  def models
    @auto_only ? MODELS_AUTO_ONLY : MODELS
  end

  def determine_start_index(model_index_from_request, start_model_index)
    if @session_continuation
      model_index_from_request ? [model_index_from_request, @current_model_index].max : @current_model_index
    else
      @current_model_index = 0
      model_index_from_request || start_model_index
    end
  end

  def initialize_run(request)
    update_terminal_title('Initializing...')
    @display.check_late_night_reminder
    @start_time = Time.now unless request
    @git_initialized_this_run = @display.suggest_git_init if request.nil?
    @display.update_git_status unless request
  end

  ATTEMPTS_PER_MODEL = 2

  def execute_attempts(start_index, req)
    @current_model_index = start_index
    @attempt_count_per_model = {} unless @session_continuation
    highest_index_reached = start_index
    early_exit = nil
    models[@current_model_index..-1].each_with_index do |model, relative_idx|
      idx = @current_model_index + relative_idx
      @current_pass = idx + 1
      @current_model = model
      highest_index_reached = idx if idx > highest_index_reached
      next if (@attempt_count_per_model[model] || 0) >= ATTEMPTS_PER_MODEL

      result = run_model_attempt(model, idx, req)
      break if result == :success
      if result == :switch_to_auto_only
        @display.puts 'Usage limit reached; switching to auto-only model queue.'.yellow
        execute_attempts(0, req)
        early_exit = true
        break
      end
    end
    return if early_exit

    @current_model_index = highest_index_reached
  end

  def run_model_attempt(model, idx, req)
    attempt_number = (@attempt_count_per_model[model] || 0) + 1
    update_terminal_title("Attempting: #{model} (attempt #{attempt_number}/#{ATTEMPTS_PER_MODEL})")
    @display.display_attempt_header(model, idx, models.size)

    start = Time.now
    run_opts = { new_session: !@session_continuation }
    success, output, reason = @agent_executor.run(model, req, **run_opts)
    elapsed = Time.now - start

    unless success
      return record_network_failure(model, output, elapsed, reason) || :continue
    end

    @current_implementation_time = elapsed
    @current_agent_output = output
    save_agent_summary(output) if output && !output.to_s.strip.empty?

    result = process_verification_and_fix(model, req)
    record_attempt_failure(model) if result != :success
    result
  end

  def record_network_failure(model, output, implementation_time, reason = nil)
    if @agent_executor.usage_unrecoverable?(output)
      AutoOnlyLock.create
      @auto_only = true
    end
    @attempt_count_per_model[model] = (@attempt_count_per_model[model] || 0) + 1
    @display.display_agent_failure(output, reason)
    pass_timing = {
      pass: @current_pass,
      model: model,
      implementation_time: implementation_time,
      review_time: 0,
      fix_time: 0,
      total_time: implementation_time
    }
    @pass_timings << pass_timing
    @display.display_pass_timing(pass_timing)
    @auto_only ? :switch_to_auto_only : nil
  end

  def process_verification_and_fix(model, req)
    pass_start = Time.now
    pass_timing = {
      pass: @current_pass,
      model: model,
      implementation_time: @current_implementation_time,
      review_time: 0,
      fix_time: 0,
      total_time: 0
    }

    update_terminal_title("Verifying: #{model}")
    run_verification_with_retries(model, req)
    h = @verification_handler
    pass_timing[:review_time] = h.review_time
    @display.out_puts ''

    if h.call_failed
      record_attempt_failure(model)
      usage_output = (h.raw_output && !h.raw_output.empty?) ? h.raw_output : h.desc
      if @agent_executor.usage_unrecoverable?(usage_output)
        AutoOnlyLock.create
        @auto_only = true
      end
      @display.display_verification_result(false, h.desc, '', call_failed: true)
      @display.out_puts ''
      pass_timing[:total_time] = Time.now - pass_start + @current_implementation_time
      @pass_timings << pass_timing
      @display.display_pass_timing(pass_timing)
      return :switch_to_auto_only if @auto_only
      return :continue
    end

    if h.verified
      finalize_success(pass_timing, pass_start, h.desc, req)
      return :success
    end

    @display.display_verification_result(false, h.desc)
    @display.out_puts ''
    retry_verification_with_fix(model, req, pass_timing, pass_start)
  end

  VERIFICATION_CALL_RETRIES = 2

  def run_verification_with_retries(model, req)
    exhausted = true
    (VERIFICATION_CALL_RETRIES + 1).times do |attempt|
      @verification_handler.run_verification(model, req, @current_agent_output)
      h = @verification_handler
      unless h.call_failed && h.retryable
        exhausted = false
        break
      end
      break if attempt >= VERIFICATION_CALL_RETRIES

      @display.puts 'Connection/network error during verification (retrying up to 3 times)...'.yellow
      @display.out_puts ''
    end
    h = @verification_handler
    @verification_handler.finalize_call_failed(h.verified, h.desc, h.review_time, h.raw_output) if exhausted
  end

  def retry_verification_with_fix(model, req, pass_timing, pass_start)
    update_terminal_title("Retrying: #{model}")
    fix_start = Time.now
    @verification_handler.retry_with_fix(model, req)
    h = @verification_handler
    pass_timing[:fix_time] = Time.now - fix_start - (h.review_time || 0)
    pass_timing[:review_time] += (h.review_time || 0)
    @display.out_puts ''
    save_agent_summary(h.fix_output) if h.fix_output

    if h.verified
      finalize_success(pass_timing, pass_start, h.desc, req, 'after retry')
      return :success
    end

    @last_attempt_success = false
    @display.display_verification_result(false, h.desc, 'after retry')
    @display.out_puts ''
    pass_timing[:total_time] = Time.now - pass_start + @current_implementation_time
    @pass_timings << pass_timing
    @display.display_pass_timing(pass_timing)
    :continue
  end

  def finalize_success(pass_timing, pass_start, desc, req, context = '')
    pass_timing[:total_time] = Time.now - pass_start + @current_implementation_time
    @pass_timings << pass_timing
    handle_success(desc, context)
    handle_final_success(req)
    @last_attempt_success = true
  end

  def record_attempt_failure(model)
    @attempt_count_per_model[model] = (@attempt_count_per_model[model] || 0) + 1
  end

  def add_active_segment
    return unless @active_start

    @active_elapsed += Time.now - @active_start
    @active_start = nil
  end

  def add_waiting_segment
    return unless @waiting_start

    @waiting_elapsed += Time.now - @waiting_start
    @waiting_start = nil
  end

  def finalize_runtime_before_display
    add_active_segment
    add_waiting_segment
  end


  def handle_success(desc, context = '')
    @display.display_git_status
    @display.display_session_description(@session_description) if @session_description
    @display.display_feature_timing(@pass_timings, @feature_start_time) if @feature_start_time
    @display.display_passes_recap(@pass_timings)
    @display.display_verification_result(true, desc, context)
    finalize_runtime_before_display
    @display.display_total_runtime(@start_time, active_elapsed: @active_elapsed, waiting_elapsed: @waiting_elapsed)
  end

  def handle_final_success(previous_req = nil)
    update_terminal_title(true)
    current_req = previous_req || @current_request
    @session_outcomes << { request: current_req, success: true }
    save_current_session(current_req) if current_req
    @display.display_done_requests_recap(@session_outcomes) if @session_outcomes.any?
    ensure_pending_input_stopped

    pending = @pending_queue.take_all
    CompletionNotifier.notify_completion(success: true) if pending.empty?
    if pending.any?
      combined = @pending_queue.to_combined_request(pending)
      @display.display_pending_list(pending)
      InstanceLock.release_lock(InstanceLock.current_lock_path) if InstanceLock.current_lock_path
      exit 1 unless InstanceLock.acquire_lock
      model_index = extract_model_index(combined)
      execute_new_request(combined, previous_req, model_index)
    else
      InstanceLock.release_lock(InstanceLock.current_lock_path) if InstanceLock.current_lock_path
      add_active_segment
      prompt_for_new_request(previous_req)
    end
  end

  def show_request_prompt
    $stdout.puts "\n#{RequestReader::REQUEST_PROMPT}\n\n"
    $stdout.flush
  end

  def prompt_for_new_request(previous_req)
    update_terminal_title('✅ Passed')
    show_request_prompt

    @waiting_start = Time.now
    raw_new_req = @request_reader.read_interactive_silent
    if @waiting_start
      @waiting_elapsed += Time.now - @waiting_start
      @waiting_start = nil
    end
    @request_reader.add_to_request_history(raw_new_req) unless raw_new_req.to_s.strip.empty?
    @active_start = Time.now
    exit 0 if raw_new_req.to_s.strip.empty?

    model_index = extract_model_index(raw_new_req)
    new_req = sanitize_request(raw_new_req)
    return if new_req.to_s.strip.empty?

    exit 1 unless InstanceLock.acquire_lock
    execute_new_request(new_req, previous_req, model_index)
  end

  def execute_new_request(new_req, previous_req, model_index)
    analysis = if @resume_enabled
                 previous_session = previous_req ? {request: previous_req} : nil
                 @session_tracker.analyze_continuation_and_description(new_req, previous_session)
               else
                 {continuation: false, tags: [], description: nil}
               end
    if analysis[:continuation] && user_disagrees_with_verification?(analysis[:tags])
      record_attempt_failure(@current_model)
    end

    start_index = analysis[:continuation] ? [model_index || 0, @current_model_index].max : (model_index || 0)
    start_index = [[start_index, 0].max, models.size - 1].min

    display_continuation_message(analysis, start_index)
    @request_reader = RequestReader.new(@display)
    @request_reader.instance_variable_set(:@plan_mode, false)
    run(start_model_index: start_index, request: new_req, continuation_analysis: analysis)
  end

  def display_continuation_message(analysis, start_index)
    continuation_text = analysis[:continuation] ? 'continuation' : 'new request'
    tags_text = analysis[:tags].empty? ? '' : " [#{analysis[:tags].join(', ')}]"
    @display.puts "\nStarting #{continuation_text}#{tags_text} from #{models[start_index]}...\n\n".yellow
  end

  def handle_plan_success
    finalize_runtime_before_display
    @display.display_total_runtime(@start_time, active_elapsed: @active_elapsed, waiting_elapsed: @waiting_elapsed)
    @display.display_git_status
    CompletionNotifier.notify_completion(success: true)
    update_terminal_title(true)
    exit 0
  end

  def handle_final_failure
    @session_outcomes << { request: @current_request, success: false } if @current_request
    ensure_pending_input_stopped
    no_queued = @pending_queue.size == 0
    @display.display_git_status
    @display.display_session_description(@session_description) if @session_description
    @display.display_feature_timing(@pass_timings, @feature_start_time) if @feature_start_time
    @display.display_all_attempts_failed(@current_request)
    @display.display_done_requests_recap(@session_outcomes) if @session_outcomes.any?
    finalize_runtime_before_display
    @display.display_total_runtime(@start_time, active_elapsed: @active_elapsed, waiting_elapsed: @waiting_elapsed)
    save_current_session(@current_request) if @current_request
    CompletionNotifier.notify_completion(success: false) if no_queued
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
    project_name = File.basename(Dir.pwd)
    title = "#{project_name}: #{title}"
    sequence = "\033]0;#{title}\007"
    $stderr.print sequence if $stderr.tty?
    $stderr.flush if $stderr.tty?
  rescue StandardError
    # Ignore terminal title update errors
  end

  def apply_continuation_analysis(analysis)
    @session_continuation = analysis[:continuation]
    @session_tags = analysis[:tags] || []
    @session_description = analysis[:description]
    previous_session = @session_tracker.load_previous_session
    if @session_continuation && previous_session && previous_session[:agent_session_id]
      @agent_executor.resume_with_session_id(previous_session[:agent_session_id])
    end
  end

  def analyze_session_continuation(req)
    previous_session = @session_tracker.load_previous_session
    analysis = @session_tracker.analyze_continuation_and_description(req, previous_session)
    apply_continuation_analysis(analysis)
  end

  def save_current_session(req, summary = :not_provided)
    @session_tracker.save_session(
      req, @session_description, @session_tags, @session_continuation, summary,
      agent_session_id: @agent_executor.agent_session_id
    )
  end

  def save_agent_summary(summary)
    save_current_session(@current_request, summary) if summary && !summary.to_s.strip.empty? && @current_request
  end

  def prepend_gitignore_instruction(raw_req)
    base = raw_req.to_s.strip
    base.empty? ? GITIGNORE_PREPEND.strip : "#{GITIGNORE_PREPEND}#{raw_req}"
  end

  def sanitize_request(req)
    return req if req.nil?

    remove_model_mentions(req.gsub(NON_INTERACTIVE_NOTICE, "\n").strip).gsub(/\n{3,}/, "\n\n")
  end

  def extract_model_index(req)
    return nil if req.nil?

    req.scan(/@(\S+)/).flatten.each do |mention|
      model_index = models.index(mention)
      return model_index if model_index
    end
    nil
  end

  def remove_model_mentions(req)
    return req if req.nil?

    cleaned = req.gsub(/@(\S+)/) do |match|
      models.include?($1) ? '' : match
    end
    cleaned.gsub(/\s+/, ' ').strip
  end

  def user_disagrees_with_verification?(tags)
    tags.any? { |tag| %w[#bug #regression #hotfix].include?(tag) }
  end

  def start_pending_input_thread
    return if @input_thread&.alive?

    reader, @input_wakeup_writer = IO.pipe
    queue = @pending_queue
    current_request = @current_request
    @input_thread = Thread.new { run_pending_input_loop(reader, queue, current_request) }
  end

  def run_pending_input_loop(reader, queue, current_request)
    buffer = []
    input_io = nil
    input_io = open_controlling_tty
    run_pending_input_loop_cooked(reader, queue, current_request, buffer, input_io)
  rescue StandardError
    # Silently ignore input errors in background thread
  ensure
    input_io&.close if input_io && input_io != $stdin
    reader.close rescue nil
  end

  def open_controlling_tty
    File.open('/dev/tty', 'r')
  rescue StandardError
    $stdin
  end

  ENTER_SIGNAL_DELAY = 0.5

  def run_pending_input_loop_cooked(reader, queue, current_request, buffer, input_io)
    return unless input_io

    thread_start = Time.now
    read_ios = [reader, input_io].compact
    loop do
      drain_pending_file(queue, current_request)
      ready = IO.select(read_ios, nil, nil, 0.5)
      next if ready.nil?
      break flush_and_close(reader, buffer, queue, current_request) if ready[0].include?(reader)
      next unless ready[0].include?(input_io)

      line = input_io.gets
      break if line.nil?

      if single_enter?(line, buffer) && (Time.now - thread_start) >= ENTER_SIGNAL_DELAY
        handle_queue_request_in_thread(queue, input_io)
        next
      end
      buffer = process_pending_line(line.chomp, buffer, queue, current_request)
    end
  end

  def drain_pending_file(queue, current_request)
    return unless InstanceLock.current_lock_path
    path = InstanceLock.pending_file_path
    return unless File.exist?(path)

    content = nil
    File.open(path, "r+") do |f|
      f.flock(File::LOCK_EX)
      content = f.read
      f.rewind
      f.truncate(0)
    end
    requests = content.to_s.split(InstanceLock::PENDING_DELIMITER).map(&:strip).reject(&:empty?)
    requests.each { |r| queue.add(r, current_request: current_request) }
  end

  def single_enter?(line, buffer)
    line.chomp.empty? && buffer.empty?
  end

  def handle_queue_request_in_thread(queue, input_io)
    @display.set_output_paused(true)
    $stdout.puts "\n#{RequestReader::REQUEST_PROMPT}\n\n"
    $stdout.flush

    lines = []
    saw_empty = false
    last_time = Time.now
    loop do
      line = input_io.gets
      break if line.nil?

      now = Time.now
      elapsed = now - last_time
      last_time = now

      line_stripped = line.to_s.strip
      action = pending_empty_action(line_stripped, lines.empty?, elapsed, saw_empty)
      case action
      when :break then break
      when :add_empty then lines << ''; next
      when :set_saw_empty then saw_empty = true; next
      else saw_empty = false; lines << line_stripped
      end
    end

    @display.set_output_paused(false)
    $stdout.puts ''
    @display.flush_paused_output
    @display.reset_after_pause

    result = lines.join("\n")
    return (queue.take_all; @display.puts 'Queued requests discarded.'.yellow) if RequestReader.discard_command?(result)

    add_and_show_queue(queue, result, @current_request)
  end

  def pending_empty_action(line_stripped, lines_empty, elapsed, saw_empty)
    return :content unless line_stripped.empty?

    return :add_empty if elapsed < RequestReader::PASTE_THRESHOLD
    return :break if !lines_empty || saw_empty

    :set_saw_empty
  end

  def add_and_show_queue(queue, raw_new, current_request = nil)
    return if raw_new.to_s.strip.empty?

    queue.add(raw_new.to_s.strip, current_request: current_request)
    list = queue.snapshot
    @display.display_pending_list(list, current_request: current_request) unless list.empty?
  end

  def process_pending_line(line, buffer, queue, current_request)
    if line.empty? && buffer.any?
      queue.add(buffer.join("\n"), current_request: current_request)
      return []
    end
    return buffer << line unless line.empty?

    buffer
  end

  def flush_and_close(_reader, buffer, queue, current_request)
    queue.add(buffer.join("\n"), current_request: current_request) if buffer.any?
  end

  def ensure_pending_input_stopped
    return unless @input_thread&.alive?

    @input_wakeup_writer&.write('.')
    @input_wakeup_writer&.close
    @input_thread.join(2)
    @input_thread.kill if @input_thread.alive?
    @input_thread = nil
    @input_wakeup_writer = nil
  end
end
