# frozen_string_literal: true

# Encapsulates the attempt loop and verification/refactor flow for superagent runs.
module AttemptExecution
  ATTEMPTS_PER_MODEL = 2
  VERIFICATION_CALL_RETRIES = 2

  def execute_attempts(start_index, req)
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

      run_refactor_at_pass_start(model, req, run_for_this_pass: true)
      result = run_model_attempt(model, idx, req)
      return [true, highest_index_reached] if result == :success
      return [handle_switch_to_auto_only(req), highest_index_reached] if result == :switch_to_auto_only
    end
    [false, highest_index_reached]
  end

  def handle_switch_to_auto_only(req)
    @display.puts "Usage limit reached; switching to auto-only model queue.".yellow
    execute_attempts(0, req)
    true
  end

  def run_model_attempt(model, idx, req)
    run_model_attempt_start(model, idx)
    start = Time.now
    run_opts = { new_session: !@session_continuation, defer_full_prompt: false }
    success, output, reason = @agent_executor.run(model, req, **run_opts)
    elapsed = Time.now - start

    return run_model_attempt_on_failure(model, output, elapsed, reason) unless success

    run_model_attempt_on_success(output, elapsed)
    result = process_verification_and_fix(model, req)
    record_attempt_failure(model) if result != :success
    result
  end

  def run_model_attempt_start(model, idx)
    attempt_number = (@attempt_count_per_model[model] || 0) + 1
    update_terminal_title("Attempting: #{model} (attempt #{attempt_number}/#{ATTEMPTS_PER_MODEL})")
    @display.display_attempt_header(model, idx, models.size)
  end

  def run_model_attempt_on_failure(model, output, elapsed, reason)
    record_network_failure(model, output, elapsed, reason) || :continue
  end

  def run_model_attempt_on_success(output, elapsed)
    @current_implementation_time = elapsed
    @current_agent_output = output
    save_agent_summary(output) if output && !output.to_s.strip.empty?
  end

  def record_network_failure(model, output, implementation_time, reason = nil)
    if @agent_executor.usage_unrecoverable?(output)
      AutoOnlyLock.create
      @auto_only = true
    end
    @attempt_count_per_model[model] = (@attempt_count_per_model[model] || 0) + 1
    @display.display_agent_failure(output, reason)
    refactor_t = @pass_refactor_time || 0
    @pass_refactor_time = nil
    pass_timing = PassTimingBuilder.build(
      @current_pass, @current_model,
      implementation_time: implementation_time,
      refactor_time: refactor_t,
      total_time: implementation_time
    )
    @pass_timings << pass_timing
    @display.display_pass_timing(pass_timing)
    @auto_only ? :switch_to_auto_only : nil
  end

  def process_verification_and_fix(model, req)
    pass_start = Time.now
    pass_timing = build_pass_timing
    @pass_refactor_time = nil
    update_terminal_title("Verifying: #{model}")
    run_verification_with_retries(model, req)
    @session_tracker.append_to_request_history(RequestHistoryFormatter.verification_entry(req), type: "verification")
    process_verification_after_run(model, req, pass_timing, pass_start)
  end

  def build_pass_timing
    PassTimingBuilder.build(
      @current_pass, @current_model,
      implementation_time: @current_implementation_time,
      refactor_time: @pass_refactor_time || 0
    )
  end

  def process_verification_after_run(model, req, pass_timing, pass_start)
    h = @verification_handler
    pass_timing[:review_time] = h.review_time
    @display.out_puts ""
    return handle_verification_call_failed(model, pass_timing, pass_start) if h.call_failed
    if h.verified
      finalize_success(pass_timing, pass_start, h.desc, req)
      return :success
    end

    @display.display_verification_result(false, h.desc)
    @display.out_puts ""
    retry_verification_with_fix(model, req, pass_timing, pass_start)
  end

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

      @display.puts "Connection/network error during verification (retrying up to 3 times)...".yellow
      @display.out_puts ""
    end
    h = @verification_handler
    @verification_handler.finalize_call_failed(h.verified, h.desc, h.review_time, h.raw_output) if exhausted
  end

  def run_refactor_at_pass_start(model, req, run_for_this_pass: false)
    return unless run_for_this_pass

    @pass_refactor_time = 0
    @session_tracker.append_to_request_history(RequestHistoryFormatter.refactor_entry(req), type: "refactor")
    update_terminal_title("Refactoring: #{model}")
    refactor_start = Time.now
    refactor_ok = @verification_handler.run_refactor(model, req)
    @pass_refactor_time = (Time.now - refactor_start) if refactor_ok
    save_refactor_summary_if_present if refactor_ok
  end

  def save_refactor_summary_if_present
    out = @verification_handler.refactor_output
    save_agent_summary(out) if out && !out.to_s.strip.empty?
  end

  def handle_verification_call_failed(model, pass_timing, pass_start)
    h = @verification_handler
    record_attempt_failure(model)
    apply_usage_unrecoverable_if_needed(h.raw_output.to_s.empty? ? h.desc : h.raw_output)
    @display.display_verification_result(false, h.desc, "", call_failed: true)
    @display.out_puts ""
    pass_timing[:total_time] = Time.now - pass_start + @current_implementation_time
    @pass_timings << pass_timing
    @display.display_pass_timing(pass_timing)
    @auto_only ? :switch_to_auto_only : :continue
  end

  def apply_usage_unrecoverable_if_needed(usage_output)
    return unless @agent_executor.usage_unrecoverable?(usage_output)

    AutoOnlyLock.create
    @auto_only = true
  end

  def retry_verification_with_fix(model, req, pass_timing, pass_start)
    @session_tracker.append_to_request_history("Fix after verification failure", type: "fix")
    update_terminal_title("Retrying: #{model}")
    fix_start = Time.now
    @verification_handler.retry_with_fix(model, req)
    retry_verification_after_fix(pass_timing, pass_start, fix_start)
  end

  def retry_verification_after_fix(pass_timing, pass_start, fix_start)
    h = @verification_handler
    pass_timing[:fix_time] = Time.now - fix_start - (h.review_time || 0)
    pass_timing[:review_time] += h.review_time || 0
    @display.out_puts ""
    save_agent_summary(h.fix_output) if h.fix_output
    return retry_verification_success(pass_timing, pass_start, h, req) if h.verified

    retry_verification_failure(pass_timing, pass_start, h)
  end

  def retry_verification_success(pass_timing, pass_start, h, req)
    finalize_success(pass_timing, pass_start, h.desc, req, "after retry")
    :success
  end

  def retry_verification_failure(pass_timing, pass_start, h)
    @last_attempt_success = false
    @display.display_verification_result(false, h.desc, "after retry")
    @display.out_puts ""
    pass_timing[:total_time] = Time.now - pass_start + @current_implementation_time
    @pass_timings << pass_timing
    @display.display_pass_timing(pass_timing)
    :continue
  end

  def finalize_success(pass_timing, pass_start, desc, req, context = "")
    pass_timing[:total_time] = Time.now - pass_start + @current_implementation_time
    @pass_timings << pass_timing
    handle_success(desc, context)
    # Store req for main thread to call handle_final_success (Reline requires main thread)
    @agent_result_mutex.synchronize { @success_req = req }
    @last_attempt_success = true
  end

  def record_attempt_failure(model)
    @attempt_count_per_model[model] = (@attempt_count_per_model[model] || 0) + 1
  end
end
