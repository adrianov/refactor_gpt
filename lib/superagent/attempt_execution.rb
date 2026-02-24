# frozen_string_literal: true

# Encapsulates the attempt loop and verification/refactor flow for superagent runs.
# Pass order: implementation; refactor once when changed files meet RefactorNeededCheck thresholds; then verification.
module AttemptExecution
  ATTEMPTS_PER_MODEL = 2
  VERIFICATION_CALL_RETRIES = 2
  MAX_AUTOMATED_FIXES = 1

  def execute_attempts(start_index, req)
    @current_request = req
    @current_model_index = start_index
    @attempt_count_per_model = {} unless @session_continuation
    @pass_refactor_time = nil
    early_exit, highest_index_reached = execute_attempts_loop(req, start_index)
    return if early_exit

    @current_model_index = highest_index_reached
  end

  def execute_attempts_loop(req, start_index)
    highest_index_reached = start_index
    models[@current_model_index..-1].each_with_index do |model, relative_idx|
      idx = @current_model_index + relative_idx
      highest_index_reached = idx if idx > highest_index_reached
      @current_pass = idx + 1
      @current_model = model
      next if (@attempt_count_per_model[model] || 0) >= ATTEMPTS_PER_MODEL

      result = run_model_attempt(model, idx, req)
      return [true, highest_index_reached] if result == :success
      return [handle_switch_to_auto_only(req), highest_index_reached] if result == :switch_to_auto_only
      return [handle_connection_error(req), highest_index_reached] if result == :connection_error
    end
    [false, highest_index_reached]
  end

  def handle_switch_to_auto_only(req)
    execute_attempts(0, req)
    true
  end

  def handle_connection_error(_req)
    update_terminal_title(false)
    @display.puts "\n❌ Connection errors limit reached for this pass. Exiting request queue.".red
    true
  end

  def run_model_attempt(model, idx, req)
    @code_files_edited_in_run = nil
    mtimes_before = RefactorNeededCheck.mtimes_snapshot(Dir.pwd)
    success, output, elapsed, reason = run_implementation(model, idx, req)
    return run_model_attempt_on_failure(model, output, elapsed, reason) unless success

    if out_of_scope?(@current_agent_output)
      return handle_out_of_scope(model, req, elapsed)
    end

    run_refactor_step_if_triggered(model, req, mtimes_before)
    result = process_verification_and_fix(model, req)
    record_attempt_failure(model) if result != :success
    result
  end

  # Same list as refactor trigger (changed in this run). Display uses it for "Code files edited" and counter.
  def run_refactor_step_if_triggered(model, req, mtimes_before = nil)
    changed = RefactorNeededCheck.changed_files_since(Dir.pwd, mtimes_before)
    @code_files_edited_in_run = changed
    triggering = RefactorNeededCheck.files_triggering_refactor(changed)
    shotgun_count = RefactorNeededCheck.shotgun_triggered?(changed) ? changed.size : nil
    return unless triggering.any? || shotgun_count

    shotgun_paths = shotgun_count ? changed.map { |e| e[:path] } : nil
    run_refactor_step(model, req, triggering, changed_files: changed,
                      shotgun_file_count: shotgun_count, shotgun_file_paths: shotgun_paths,
                      project_root: Dir.pwd)
  end

  # Runs implementation step only (agent run, no verification). Returns success, output, elapsed, reason.
  def run_implementation(model, idx, req)
    run_model_attempt_start(model, idx, req)
    start = Time.now
    run_opts = { new_session: !@session_continuation, defer_full_prompt: false,
                 continuation_analysis: @continuation_analysis }
    success, output, reason = @agent_executor.run(model, req, **run_opts)
    elapsed = Time.now - start
    run_model_attempt_on_success(output, elapsed) if success
    [success, output, elapsed, reason]
  end


  def run_model_attempt_start(model, idx, req)
    attempt_number = (@attempt_count_per_model[model] || 0) + 1
    update_terminal_title("Attempting: #{model} (attempt #{attempt_number}/#{ATTEMPTS_PER_MODEL})")
    title = attempt_title(req)
    @display.display_attempt_header(model, idx, models.size, title: title)
  end

  def attempt_title(req)
    return RequestHistoryFormatter.queue_preview(req) if @session_description.to_s.strip.empty?
    @session_description.to_s.strip
  end

  def run_model_attempt_on_failure(model, output, elapsed, reason)
    record_network_failure(model, output, elapsed, reason) || :continue
  end

  def run_model_attempt_on_success(output, elapsed)
    @current_implementation_time = elapsed
    recap = @agent_executor.last_recap_result
    result_content = (recap && !recap.to_s.strip.empty?) ? recap : output
    @current_agent_output = result_content
    save_agent_summary(result_content) if result_content && !result_content.to_s.strip.empty?
  end

  def record_network_failure(model, output, implementation_time, reason = nil)
    if @agent_executor.usage_unrecoverable?(output)
      AutoOnlyLock.create
      @auto_only = true
      msg = last_line_from(output)
      @display.puts msg.yellow if msg
    end
    @attempt_count_per_model[model] = (@attempt_count_per_model[model] || 0) + 1
    @display.display_agent_failure(output, reason)
    refactor_t = @pass_refactor_time || 0
    @pass_refactor_time = nil
    pass_timing = PassTimingBuilder.build(
      @current_pass, @current_model,
      implementation_time: implementation_time,
      refactor_time: refactor_t
    )
    set_pass_total_time(pass_timing)
    @pass_timings << pass_timing
    @display.display_pass_timing(pass_timing)
    return :connection_error if reason == :max_retries_exceeded
    @auto_only ? :switch_to_auto_only : nil
  end

  def process_verification_and_fix(model, req)
    pass_timing = build_pass_timing
    @pass_refactor_time = nil
    update_terminal_title("Verifying: #{model}")
    run_verification_with_retries(model, req)
    @session_tracker.append_to_request_history(RequestHistoryFormatter.verification_entry(req), type: "verification")
    process_verification_after_run(model, req, pass_timing)
  end

  def build_pass_timing
    PassTimingBuilder.build(
      @current_pass, @current_model,
      implementation_time: @current_implementation_time,
      refactor_time: @pass_refactor_time || 0
    )
  end

  def process_verification_after_run(model, req, pass_timing)
    h = @verification_handler
    pass_timing[:review_time] = h.review_time
    @display.out_puts ""
    return handle_verification_call_failed(model, pass_timing) if h.call_failed
    if h.verified
      finalize_success(pass_timing, h.desc, req)
      return :success
    end

    @display.display_verification_result(false, h.desc)
    @display.out_puts ""
    retry_verification_with_fix(model, req, pass_timing)
  end

  def recent_requests_for_verification(req)
    list = @session_tracker.get_session_request_history(exclude_equal: req, description: @session_description)
    list&.last(AgentPromptBuilder::MAX_PREVIOUS_REQUESTS) || []
  end

  def run_verification_with_retries(model, req)
    additional = recent_requests_for_verification(req)
    exhausted = true
    (VERIFICATION_CALL_RETRIES + 1).times do |attempt|
      @verification_handler.run_verification(model, req, @current_agent_output, additional_requests: additional)
      h = @verification_handler
      unless h.call_failed && h.retryable
        exhausted = false
        break
      end
      break if attempt >= VERIFICATION_CALL_RETRIES

      @display.puts "Connection/network error during verification (retrying up to 3 times)...".yellow
      @display.out_puts ""
    end
    h = @verification_handler
    @verification_handler.finalize_call_failed(h.verified, h.desc, h.review_time, h.raw_output) if exhausted
  end

  def run_refactor_step(model, req, triggering_files = [], changed_files: [], shotgun_file_count: nil,
                        shotgun_file_paths: nil, project_root: nil)
    @pass_refactor_time = 0
    @session_tracker.append_to_request_history(RequestHistoryFormatter.refactor_entry(req), type: "refactor")
    update_terminal_title("Refactoring: #{model}")
    refactor_start = Time.now
    refactor_ok = @verification_handler.run_refactor(model, req, triggering_files: triggering_files,
                                                     changed_files: changed_files,
                                                     shotgun_file_count: shotgun_file_count,
                                                     shotgun_file_paths: shotgun_file_paths,
                                                     project_root: project_root)
    @pass_refactor_time = (Time.now - refactor_start) if refactor_ok
    save_refactor_summary_if_present if refactor_ok
  end

  def save_refactor_summary_if_present
    out = @verification_handler.refactor_output
    save_agent_summary(out) if out && !out.to_s.strip.empty?
  end

  def handle_verification_call_failed(model, pass_timing)
    h = @verification_handler
    record_attempt_failure(model)
    apply_usage_unrecoverable_if_needed(h.raw_output.to_s.empty? ? h.desc : h.raw_output)
    @display.display_verification_result(false, h.desc, "", call_failed: true)
    @display.out_puts ""
    set_pass_total_time(pass_timing)
    @pass_timings << pass_timing
    @display.display_pass_timing(pass_timing)
    @auto_only ? :switch_to_auto_only : :continue
  end

  def apply_usage_unrecoverable_if_needed(usage_output)
    return unless @agent_executor.usage_unrecoverable?(usage_output)

    AutoOnlyLock.create
    @auto_only = true
    msg = last_line_from(usage_output)
    @display.puts msg.yellow if msg
  end

  def last_line_from(text)
    lines = text.to_s.lines.map(&:strip).reject(&:empty?)
    lines.last
  end
  private :last_line_from

  # Allow one automated fix with the same model (MAX_AUTOMATED_FIXES) before moving to next model.
  def retry_verification_with_fix(model, req, pass_timing)
    @session_tracker.append_to_request_history("Fix after verification failure", type: "fix")
    update_terminal_title("Retrying: #{model}")
    fix_start = Time.now
    @verification_handler.retry_with_fix(model, req, additional_requests: recent_requests_for_verification(req))
    retry_verification_after_fix(pass_timing, fix_start, req)
  end

  def retry_verification_after_fix(pass_timing, fix_start, req)
    h = @verification_handler
    pass_timing[:fix_time] = Time.now - fix_start - (h.review_time || 0)
    pass_timing[:review_time] += h.review_time || 0
    @display.out_puts ""
    save_agent_summary(h.fix_output) if h.fix_output
    return retry_verification_success(pass_timing, h, req) if h.verified

    retry_verification_failure(pass_timing, h)
  end

  def retry_verification_success(pass_timing, h, req)
    @applied_fix_this_run = true
    finalize_success(pass_timing, h.desc, req, "after retry")
    :success
  end

  def retry_verification_failure(pass_timing, h)
    @last_attempt_success = false
    @display.display_verification_result(false, h.desc, "after retry")
    @display.out_puts ""
    set_pass_total_time(pass_timing)
    @pass_timings << pass_timing
    @display.display_pass_timing(pass_timing)
    :continue
  end

  def finalize_success(pass_timing, desc, req, context = "")
    set_pass_total_time(pass_timing)
    @pass_timings << pass_timing
    handle_success(desc, context)
    # Store req for main thread to call handle_final_success (Reline requires main thread)
    @agent_result_mutex.synchronize { @success_req = req }
    @last_attempt_success = true
  end

  def set_pass_total_time(pass_timing)
    pass_timing[:total_time] = PassTimingBuilder.phase_times_sum(pass_timing)
  end

  def record_attempt_failure(model)
    @attempt_count_per_model[model] = (@attempt_count_per_model[model] || 0) + 1
  end

  def out_of_scope?(result_content)
    result_content.to_s.include?(AgentPromptBuilder::OUT_OF_SCOPE_MARKER)
  end

  def handle_out_of_scope(model, _req, implementation_time)
    @display.puts "Request out of scope (#{AgentPromptBuilder::OUT_OF_SCOPE_MARKER}). Skipping verification.".yellow
    record_attempt_failure(model)
    pass_timing = PassTimingBuilder.build(
      @current_pass, model,
      implementation_time: implementation_time,
      refactor_time: 0
    )
    set_pass_total_time(pass_timing)
    @pass_timings << pass_timing
    @display.display_pass_timing(pass_timing)
    :continue
  end
end
