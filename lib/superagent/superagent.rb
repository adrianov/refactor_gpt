# frozen_string_literal: true

# Main orchestrator class for superagent execution
class Superagent
  include AttemptExecution

  # Single source for model queue. @-mention hints (tags) resolve in RequestPreparer: exact match, then word-boundary.
  MODELS = %w[
    auto
    grok
    gemini-3-flash
    composer-1
    sonnet-4.5
    opus-4.5
    sonnet-4.5-thinking
    opus-4.5-thinking
  ].freeze
  MODELS_AUTO_ONLY = Array.new(3, MODELS.first).freeze

  def initialize(
    display: Display.new,
    request_reader: nil,
    agent_executor: nil,
    verification_handler: nil,
    session_tracker: nil,
    auto_only: false,
    show_full_prompt: true
  )
    @display = display
    @session_tracker = session_tracker || SessionTracker.new(@display)
    @request_reader = request_reader || RequestReader.new(@display)
    @agent_executor = agent_executor ||
      AgentExecutor.new(@display, session_tracker: @session_tracker, show_full_prompt: show_full_prompt)
    @verification_handler = verification_handler || VerificationHandler.new(@display, @agent_executor)
    initialize_runtime_state
    @auto_only = auto_only
    @git_initialized_this_run = false
  end

  def initialize_runtime_state
    initialize_runtime_timing
    initialize_runtime_session
  end

  def initialize_runtime_timing
    @start_time = nil
    @active_elapsed = 0
    @waiting_elapsed = 0
    @active_start = nil
    @waiting_start = nil
    @feature_start_time = nil
    @pass_timings = []
  end

  def initialize_runtime_session
    @current_pass = nil
    @current_model = nil
    @current_model_index = 0
    @session_description = nil
    @session_tags = []
    @session_continuation = false
    @current_request = nil
    @attempt_count_per_model = {}
    @pending_queue = PendingRequestQueue.new(@display)
    @session_outcomes = []
    @agent_thread = nil
    @agent_result_mutex = Mutex.new
  end

  def run(start_model_index: 0, request: nil, continuation_analysis: nil)
    @session_outcomes ||= []
    initialize_run(request)
    raw_req, req = run_setup_request(request)
    @current_request = req
    analysis = resolve_continuation_analysis_for_run(continuation_analysis, req)
    apply_continuation_analysis(analysis)
    save_current_session(req)

    start_index = run_start_index(raw_req, req, start_model_index)
    return run_plan_mode(req, start_index, continuation_analysis: @continuation_analysis) if @request_reader.plan_mode

    run_start_feature
    run_with_interactive_queue(start_index, req)
  end

  def run_setup_request(request)
    raw_req = run_read_request(request)
    run_accumulate_waiting_time if @waiting_start
    @request_reader.add_to_request_history(raw_req) if request.nil? && (raw_req && !raw_req.to_s.strip.empty?)
    req = run_prepare_request(raw_req)
    [raw_req, req]
  end

  def run_start_index(raw_req, req, start_model_index)
    model_idx = model_index_from_request_text(raw_req)
    start_index = determine_start_index(model_idx, start_model_index)
    @display.display_start_message(req, @session_continuation, @session_tags)
    log_model_selection(model_idx, start_index)
    update_terminal_title(@session_continuation ? "↻ Continuing session" : "Running...")
    start_index
  end

  def log_model_selection(request_model_idx, start_index)
    model = models[start_index]
    reason = model_selection_reason(request_model_idx, start_index)
    @display.puts "Model: #{model} (#{reason})".light_black
  end

  def model_selection_reason(request_model_idx, start_index)
    return "from request hint" if request_model_idx && request_model_idx == start_index
    return "continuation" if @session_continuation
    return "from failure count" if start_index.positive?

    "default"
  end

  def run_read_request(request)
    @waiting_start = Time.now if request.nil?
    raw_req = request || @request_reader.read
    raw_req = RequestPreparer.prepend_gitignore_instruction(raw_req) if request.nil? && @git_initialized_this_run
    raw_req
  end

  def run_accumulate_waiting_time
    @waiting_elapsed += Time.now - @waiting_start
    @waiting_start = nil
  end

  def run_prepare_request(raw_req)
    req = RequestPreparer.sanitize_request(raw_req, models)
    @request_reader.validate(req)
    req
  end

  def run_start_feature
    @display.display_pending_hint
    @feature_start_time = Time.now
    @pass_timings = []
    @active_start = Time.now
  end

  # Main thread listens for Enter key and runs Reline for queue input.
  # Agent execution runs in background thread.
  def run_with_interactive_queue(start_index, req)
    @agent_result_mutex.synchronize do
      @agent_result = nil
      @success_req = nil
    end
    @agent_thread = Thread.new do
      execute_attempts(start_index, req)
      @agent_result_mutex.synchronize { @agent_result = @last_attempt_success ? :success : :failure }
    end

    begin
      run_main_input_loop
    ensure
      @agent_thread&.join
    end

    result, success_req = @agent_result_mutex.synchronize { [@agent_result, @success_req] }
    if result == :success
      handle_final_success(success_req)
    elsif result == :failure
      handle_final_failure
    end
  end

  # Main thread input loop: waits for Enter, then shows Reline prompt for queue input.
  def run_main_input_loop
    input_io = File.open("/dev/tty", "r")
    loop do
      break unless @agent_thread&.alive?

      ready = IO.select([input_io], nil, nil, 0.3)
      next unless ready

      line = input_io.gets
      break if line.nil?
      next unless line.chomp.empty? # Only react to empty Enter

      handle_queue_input_request
    end
  rescue IOError, Errno::EIO
    # Terminal closed or unavailable
  ensure
    input_io&.close
  end

  # Pause agent output, show prompt, read with Reline, add to queue, resume output.
  def handle_queue_input_request
    @display.set_output_paused(true)
    @display.flush_assistant_text_buffer

    $stdout.puts "\n#{RequestReader::REQUEST_PROMPT}\n\n"
    $stdout.flush

    raw = @request_reader.read_interactive_silent(for_queue: true)
    process_queue_input(raw) if raw
  ensure
    @display.set_output_paused(false)
    @display.flush_paused_output
    @display.reset_after_pause
  end

  def run_plan_mode(req, start_index = 0, continuation_analysis: nil)
    run_plan_mode_start
    models[start_index..-1].each_with_index do |model, relative_idx|
      idx = start_index + relative_idx
      return handle_plan_success if run_plan_mode_attempt(model, idx, req, continuation_analysis: continuation_analysis)
    end
    handle_final_failure
  end

  def run_plan_mode_start
    @active_start = Time.now
    update_terminal_title("Planning...")
    @display.puts "Running in plan mode...".cyan
    @display.out_puts ""
  end

  def run_plan_mode_attempt(model, idx, req, continuation_analysis: nil)
    @current_pass = idx + 1
    @current_model = model
    update_terminal_title("Planning: #{model}")
    @display.display_attempt_header(model, idx, models.size)
    success, output = @agent_executor.run_plan_mode(model, req, new_session: !@session_continuation,
                                                    continuation_analysis: continuation_analysis)
    @display.display_agent_failure(output, nil) unless success
    success
  end

  private

  def display_done_requests_recap_if_any
    return unless @session_outcomes.any? || @pending_queue.size.positive?

    @display.display_done_requests_recap(@session_outcomes, queued: @pending_queue.snapshot)
  end

  def models
    @auto_only ? MODELS_AUTO_ONLY : MODELS
  end

  # Session model hint from request text (e.g. @sonnet). Used to set queue start for this run.
  def model_index_from_request_text(raw_text)
    RequestPreparer.extract_model_index(raw_text, models)
  end

  # Start-index policy: continuation keeps current model; new request uses request hint or session failure_count.
  def resolve_start_index(request_model_index, _start_model_index, continuation:, current_model_index:,
                          failure_count: 0)
    if continuation
      request_model_index ? [request_model_index, current_model_index].max : current_model_index
    else
      request_model_index || [failure_count, models.size - 1].min
    end
  end

  def determine_start_index(model_index_from_request, start_model_index)
    @current_model_index = 0 unless @session_continuation
    session = @session_tracker.session_for_continuation_analysis
    failure_count = session ? (session[:failure_count] || 0) : 0
    resolve_start_index(
      model_index_from_request, start_model_index,
      continuation: @session_continuation, current_model_index: @current_model_index,
      failure_count: failure_count
    )
  end

  def initialize_run(request)
    update_terminal_title("Waiting for request...")
    @display.check_late_night_reminder
    @start_time = Time.now unless request
    @git_initialized_this_run = @display.suggest_git_init if request.nil?
    @display.update_git_status unless request
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

  # Hash for display_total_runtime. Add optional keys here and in Display::OPTIONAL_RUNTIME_STAT_LINES.
  def runtime_stats_for_display
    {
      start_time: @start_time,
      active_elapsed: @active_elapsed,
      waiting_elapsed: @waiting_elapsed,
      model: @current_model,
      current_dir: Dir.pwd
    }
  end

  # Raw agent output; do not compact (display and verification preserve formatting).
  def current_recap_text
    @current_agent_output
  end

  def handle_success(desc, context = "")
    @display.display_git_status
    @display.display_session_description(@session_description) if @session_description
    @display.display_feature_timing(@pass_timings, @feature_start_time) if @feature_start_time
    @display.display_passes_recap(@pass_timings)
    @display.display_verification_result(true, desc, context, raw_recap: current_recap_text)
    finalize_runtime_before_display
    @display.display_total_runtime(runtime_stats_for_display)
  end

  def handle_final_success(previous_req = nil)
    update_terminal_title(true)
    current_req = previous_req || @current_request
    @session_outcomes << {request: current_req, success: true}
    save_current_session(current_req) if current_req
    display_done_requests_recap_if_any

    process_pending_queue(previous_req)
  end

  def process_pending_queue(previous_req)
    pending = @pending_queue.take_all
    CompletionNotifier.notify_completion(success: true) if pending.empty?
    if pending.any?
      process_pending_with_requests(pending, previous_req)
    else
      InstanceLock.release_lock(InstanceLock.current_lock_path) if InstanceLock.current_lock_path
      add_active_segment
      prompt_for_new_request(previous_req)
    end
  end

  def process_pending_with_requests(pending, previous_req)
    combined = @pending_queue.to_combined_request(pending)
    @display.display_pending_list(pending)
    InstanceLock.release_lock(InstanceLock.current_lock_path) if InstanceLock.current_lock_path
    unless InstanceLock.acquire_lock
      msg = "Another instance is already running for this project (#{InstanceLock.project_base_name}). Exiting."
      @display.puts msg.red
      exit 1
    end
    model_index = model_index_from_request_text(combined)
    execute_new_request(combined, previous_req, model_index)
  end

  def process_queue_input(raw)
    if RequestReader.discard_command?(raw)
      @pending_queue.take_all
      @display.puts "Queued requests discarded.".yellow
      return
    end
    if RequestReader.reset_command?(raw)
      @session_tracker.reset_failure_count
      @display.puts "Failure count reset.".yellow
      return
    end
    return if raw.nil? || raw.to_s.strip.empty?

    save_request_to_histories(raw)
    add_and_show_queue(@pending_queue, RequestPreparer.normalized_request_text(raw), @current_request)
  end

  def prompt_for_new_request(previous_req)
    update_terminal_title("✅ Passed")
    @waiting_start = Time.now
    raw_new_req = @request_reader.read_request
    prompt_accumulate_waiting
    return prompt_handle_reset(previous_req) if RequestReader.reset_command?(raw_new_req)

    prompt_save_history(raw_new_req) unless raw_new_req.nil? || raw_new_req.to_s.strip.empty?
    @active_start = Time.now
    exit 0 if raw_new_req.nil? || raw_new_req.to_s.strip.empty?

    prompt_execute_new_request(raw_new_req, previous_req)
  end

  def prompt_handle_reset(previous_req)
    @session_tracker.reset_failure_count
    @display.puts "Failure count reset.".yellow
    prompt_for_new_request(previous_req)
  end

  def prompt_accumulate_waiting
    return unless @waiting_start

    @waiting_elapsed += Time.now - @waiting_start
    @waiting_start = nil
  end

  def prompt_save_history(raw_new_req)
    @request_reader.add_to_request_history(raw_new_req)
    @session_tracker.append_to_request_history(raw_new_req)
  end

  def prompt_execute_new_request(raw_new_req, previous_req)
    model_index = model_index_from_request_text(raw_new_req)
    new_req = RequestPreparer.sanitize_request(raw_new_req, models)
    return if new_req.nil? || new_req.to_s.strip.empty?

    unless InstanceLock.acquire_lock
      msg = "Another instance is already running for this project (#{InstanceLock.project_base_name}). Exiting."
      @display.puts msg.red
      exit 1
    end
    analysis = continuation_analysis_for_request(new_req)
    execute_new_request(new_req, previous_req, model_index, continuation_analysis: analysis)
  end

  def resolve_continuation_analysis_for_run(explicit_analysis, sanitized_req)
    return explicit_analysis if explicit_analysis

    continuation_analysis_for_request(sanitized_req)
  end

  def run_continuation_analysis(sanitized_req, previous_session)
    return default_continuation_analysis unless previous_session

    @session_tracker.analyze_continuation_and_description(sanitized_req, previous_session)
  rescue StandardError => e
    @display.puts "Warning: Continuation analysis failed: #{e.message}".yellow
    default_continuation_analysis
  end

  def continuation_analysis_for_request(sanitized_req)
    run_continuation_analysis(sanitized_req, @session_tracker.session_for_continuation_analysis)
  end

  def default_continuation_analysis
    {continuation: false, tags: [], description: nil}
  end

  def execute_new_request(new_req, _previous_req, model_index, continuation_analysis: nil)
    analysis = continuation_analysis || default_continuation_analysis
    session = @session_tracker.session_for_continuation_analysis
    failure_count = session ? (session[:failure_count] || 0) : 0
    start_index = resolve_start_index(
      model_index, 0,
      continuation: analysis[:continuation], current_model_index: @current_model_index,
      failure_count: failure_count
    )
    start_index = [[start_index, 0].max, models.size - 1].min

    display_continuation_message(analysis, start_index)
    @request_reader = RequestReader.new(@display)
    @request_reader.instance_variable_set(:@plan_mode, false)
    run(start_model_index: start_index, request: new_req, continuation_analysis: analysis)
  end

  def display_continuation_message(analysis, start_index)
    tags = analysis[:tags] || []
    continuation_text = analysis[:continuation] ? "continuation" : "new request"
    tags_text = tags.empty? ? "" : " [#{tags.join(", ")}]"
    @display.puts "\nStarting #{continuation_text}#{tags_text} from #{models[start_index]}...\n\n".yellow
  end

  def handle_plan_success
    finalize_runtime_before_display
    @display.display_total_runtime(runtime_stats_for_display)
    @display.display_git_status
    CompletionNotifier.notify_completion(success: true)
    update_terminal_title(true)
    exit 0
  end

  def handle_final_failure
    @session_outcomes << {request: @current_request, success: false} if @current_request
    no_queued = @pending_queue.size == 0
    @display.display_git_status
    @display.display_session_description(@session_description) if @session_description
    @display.display_feature_timing(@pass_timings, @feature_start_time) if @feature_start_time
    @display.display_all_attempts_failed(@current_request)
    display_done_requests_recap_if_any
    finalize_runtime_before_display
    @display.display_total_runtime(runtime_stats_for_display)
    if @current_request
      @session_tracker.increment_failure_count
      save_current_session(@current_request)
    end
    CompletionNotifier.notify_completion(success: false) if no_queued
    update_terminal_title(false)
    exit 1
  end

  def update_terminal_title(phase)
    return unless $stdout.tty? || $stderr.tty?

    title = case phase
    when true then "✅ Done"
    when false then "❌ Error"
    else phase.to_s
    end
    title = "#{InstanceLock.project_base_name}: #{title}"
    sequence = "\033]0;#{title}\007"
    $stderr.print sequence if $stderr.tty?
    $stderr.flush if $stderr.tty?
  rescue
    # Ignore terminal title update errors
  end

  def apply_continuation_analysis(analysis)
    @continuation_analysis = analysis
    @session_continuation = analysis[:continuation]
    @session_tags = analysis[:tags] || []
    @session_description = analysis[:description]
  end

  def save_request_to_histories(raw)
    @request_reader.add_to_request_history(raw)
    @session_tracker.append_to_request_history(raw)
  end

  def save_current_session(req, summary = :not_provided)
    @session_tracker.save_session(
      req, @session_description, @session_tags, @session_continuation, summary
    )
  end

  def save_agent_summary(summary)
    save_current_session(@current_request, summary) if (summary && !summary.to_s.strip.empty?) && @current_request
  end

  def add_and_show_queue(queue, raw_new, current_request = nil)
    return if raw_new.nil? || raw_new.to_s.strip.empty?

    queue.add(RequestPreparer.normalized_request_text(raw_new))
    list = queue.snapshot
    @display.display_pending_list(list, current_request: current_request) unless list.empty?
  end
end
