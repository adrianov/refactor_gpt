# frozen_string_literal: true

require_relative "display"
require_relative "request_reader"
require_relative "agent_executor"
require_relative "verification_handler"
require_relative "session_tracker"
require_relative "pending_request_queue"
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

  def initialize(
    display: Display.new,
    request_reader: nil,
    agent_executor: nil,
    verification_handler: nil,
    session_tracker: nil
  )
    @display = display
    @session_tracker = session_tracker || SessionTracker.new(@display)
    @request_reader = request_reader || RequestReader.new(@display)
    @agent_executor = agent_executor || AgentExecutor.new(
      @display,
      session_tracker: @session_tracker
    )
    @verification_handler = verification_handler || VerificationHandler.new(
      @display,
      @agent_executor,
      session_tracker: @session_tracker
    )
    @start_time = nil
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
    @input_thread = nil
    @input_wakeup_writer = nil
  end

  def run(start_model_index: 0, request: nil)
    initialize_run(request)
    raw_req = request || @request_reader.read
    model_index_from_request = extract_model_index(raw_req)
    req = sanitize_request(raw_req)
    @request_reader.validate(req)
    @current_request = req
    
    analyze_session_continuation(req)
    @agent_executor.reset_agent_session unless @session_continuation
    save_current_session(req)
    
    start_index = determine_start_index(model_index_from_request, start_model_index)
    @display.display_start_message(req, @session_continuation, @session_tags)

    return run_plan_mode(req, start_index) if @request_reader.plan_mode

    @display.display_pending_hint if $stdin.tty?
    start_pending_input_thread if $stdin.tty?
    @feature_start_time = Time.now
    @pass_timings = []
    execute_attempts(start_index, req)
    handle_final_failure unless @last_attempt_success
  end

  def run_plan_mode(req, start_index = 0)
    update_terminal_title('Planning...')
    @display.puts 'Running in plan mode...'.cyan
    $stdout.puts ''

    MODELS[start_index..-1].each_with_index do |model, relative_idx|
      idx = start_index + relative_idx
      @current_pass = idx + 1
      @current_model = model
      update_terminal_title("Planning: #{model}")
      @display.display_attempt_header(model, idx, MODELS.size)

      success, output = @agent_executor.run_plan_mode(model, req, new_session: !@session_continuation)
      return handle_plan_success if success

      @display.display_agent_failure(output)
    end

    handle_final_failure
  end

  private

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
    @display.suggest_git_init unless request
    @display.update_git_status unless request
  end

  ATTEMPTS_PER_MODEL = 2

  def execute_attempts(start_index, req)
    @current_model_index = start_index
    @attempt_count_per_model = {} unless @session_continuation
    highest_index_reached = start_index
    MODELS[@current_model_index..-1].each_with_index do |model, relative_idx|
      idx = @current_model_index + relative_idx
      @current_pass = idx + 1
      @current_model = model
      highest_index_reached = idx if idx > highest_index_reached
      next if (@attempt_count_per_model[model] || 0) >= ATTEMPTS_PER_MODEL

      break if run_model_attempt(model, idx, req) == :success
    end
    @current_model_index = highest_index_reached
  end

  def run_model_attempt(model, idx, req)
    attempt_number = (@attempt_count_per_model[model] || 0) + 1
    update_terminal_title("Attempting: #{model} (attempt #{attempt_number}/#{ATTEMPTS_PER_MODEL})")
    @display.display_attempt_header(model, idx, MODELS.size)
    show_queue_reminder_if_tty

    start = Time.now
    success, output, = @agent_executor.run(model, req, new_session: !@session_continuation)
    elapsed = Time.now - start

    unless success
      record_network_failure(model, output, elapsed)
      return :continue
    end

    @current_implementation_time = elapsed
    @current_agent_output = output
    save_agent_summary(output) if output&.strip && !output.strip.empty?

    result = process_verification_and_fix(model, req)
    record_attempt_failure(model) if result != :success
    result
  end

  def record_network_failure(model, output, implementation_time)
    @attempt_count_per_model[model] = (@attempt_count_per_model[model] || 0) + 1
    @display.display_agent_failure(output)
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
    verified, desc, review_time = @verification_handler.run_verification(model, req, @current_agent_output)
    pass_timing[:review_time] = review_time
    $stdout.puts ''

    if verified
      finalize_success(pass_timing, pass_start, desc, req)
      return :success
    end

    @display.display_verification_result(false, desc)
    $stdout.puts ''
    retry_verification_with_fix(model, req, pass_timing, pass_start)
  end

  def retry_verification_with_fix(model, req, pass_timing, pass_start)
    update_terminal_title("Retrying: #{model}")
    fix_start = Time.now
    verified, desc, review_time, fix_output = @verification_handler.retry_with_fix(model, req)
    pass_timing[:fix_time] = Time.now - fix_start - (review_time || 0)
    pass_timing[:review_time] += (review_time || 0)
    $stdout.puts ''
    save_agent_summary(fix_output) if fix_output

    if verified
      finalize_success(pass_timing, pass_start, desc, req, 'after retry')
      return :success
    end

    @last_attempt_success = false
    @display.display_verification_result(false, desc, 'after retry')
    $stdout.puts ''
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


  def handle_success(desc, context = '')
    @display.display_verification_result(true, desc, context)
    @display.display_total_runtime(@start_time)
    @display.display_git_diff
    @display.display_feature_timing(@pass_timings, @feature_start_time) if @feature_start_time
    @display.display_passes_recap(@pass_timings)
    @display.display_git_status
    @display.display_session_description(@session_description) if @session_description
  end

  def handle_final_success(previous_req = nil)
    update_terminal_title(true)
    CompletionNotifier.notify_completion(success: true)
    current_req = previous_req || @current_request
    save_current_session(current_req) if current_req
    ensure_pending_input_stopped
    return unless $stdin.tty?

    pending = @pending_queue.take_all
    if pending.any?
      combined = @pending_queue.to_combined_request(pending)
      @display.display_pending_list(pending)
      InstanceLock.release_lock(InstanceLock.current_lock_path) if InstanceLock.current_lock_path
      exit 1 unless InstanceLock.acquire_lock
      model_index = extract_model_index(combined)
      execute_new_request(combined, previous_req, model_index)
    else
      InstanceLock.release_lock(InstanceLock.current_lock_path) if InstanceLock.current_lock_path
      prompt_for_new_request(previous_req)
    end
  end

  def prompt_for_new_request(previous_req)
    update_terminal_title('✅ Passed')
    $stdout.puts "\nEnter the new request:\n(Press Enter twice, Ctrl+D, or Ctrl+C to submit/exit)\n\n"

    raw_new_req = @request_reader.read_interactive_silent
    return if raw_new_req.to_s.strip.empty?

    model_index = extract_model_index(raw_new_req)
    new_req = sanitize_request(raw_new_req)
    return if new_req.to_s.strip.empty?

    exit 1 unless InstanceLock.acquire_lock
    execute_new_request(new_req, previous_req, model_index)
  end

  def execute_new_request(new_req, previous_req, model_index)
    analysis = @session_tracker.analyze_continuation(new_req, previous_req ? {request: previous_req} : nil)
    if analysis[:continuation] && user_disagrees_with_verification?(analysis[:tags])
      record_attempt_failure(@current_model)
    end
    
    start_index = analysis[:continuation] ? [model_index || 0, @current_model_index].max : (model_index || 0)
    start_index = [[start_index, 0].max, MODELS.size - 1].min

    display_continuation_message(analysis, start_index)
    @request_reader = RequestReader.new(@display)
    @request_reader.instance_variable_set(:@plan_mode, false)
    run(start_model_index: start_index, request: new_req)
  end

  def display_continuation_message(analysis, start_index)
    continuation_text = analysis[:continuation] ? 'continuation' : 'new request'
    tags_text = analysis[:tags].empty? ? '' : " [#{analysis[:tags].join(', ')}]"
    @display.puts "\nStarting #{continuation_text}#{tags_text} from #{MODELS[start_index]}...\n\n".yellow
  end

  def handle_plan_success
    @display.display_total_runtime(@start_time)
    @display.display_git_status
    CompletionNotifier.notify_completion(success: true)
    update_terminal_title(true)
    exit 0
  end

  def handle_final_failure
    ensure_pending_input_stopped
    @display.display_all_attempts_failed
    @display.display_total_runtime(@start_time)
    @display.display_feature_timing(@pass_timings, @feature_start_time) if @feature_start_time
    @display.display_git_status
    @display.display_session_description(@session_description) if @session_description
    save_current_session(@current_request) if @current_request
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

  def analyze_session_continuation(req)
    previous_session = @session_tracker.load_previous_session
    
    if previous_session
      analysis = @session_tracker.analyze_continuation(req, previous_session)
      @session_continuation = analysis[:continuation]
      @session_tags = analysis[:tags]
    else
      @session_continuation = false
      classification = @session_tracker.classify_request(req)
      @session_tags = classification[:tags]
    end
    
    @session_description = @session_tracker.generate_session_description(req, @session_tags)
  end

  def save_current_session(req, summary = :not_provided)
    @session_tracker.save_session(req, @session_description, @session_tags, @session_continuation, summary)
  end

  def save_agent_summary(summary)
    save_current_session(@current_request, summary) if summary&.strip && !summary.strip.empty? && @current_request
  end

  def sanitize_request(req)
    return req if req.nil?

    remove_model_mentions(req.gsub(NON_INTERACTIVE_NOTICE, "\n").strip).gsub(/\n{3,}/, "\n\n")
  end

  def extract_model_index(req)
    return nil if req.nil?

    req.scan(/@(\S+)/).flatten.each do |mention|
      model_index = MODELS.index(mention)
      return model_index if model_index
    end
    nil
  end

  def remove_model_mentions(req)
    return req if req.nil?

    cleaned = req.gsub(/@(\S+)/) do |match|
      MODELS.include?($1) ? '' : match
    end
    cleaned.gsub(/\s+/, ' ').strip
  end

  def user_disagrees_with_verification?(tags)
    tags.any? { |tag| %w[#bug #regression #hotfix].include?(tag) }
  end

  def show_queue_reminder_if_tty
    return unless $stdin.tty?

    @display.display_pending_queue_reminder(@pending_queue.size)
  end

  def start_pending_input_thread
    return if @input_thread&.alive?

    reader, @input_wakeup_writer = IO.pipe
    queue = @pending_queue
    @input_thread = Thread.new { run_pending_input_loop(reader, queue) }
  end

  def run_pending_input_loop(reader, queue)
    buffer = []
    loop do
      ready = IO.select([$stdin, reader], nil, nil, 0.5)
      break if ready.nil?
      break flush_and_close(reader, buffer, queue) if ready[0].include?(reader)
      next unless ready[0].include?($stdin)

      line = $stdin.gets
      break if line.nil?

      buffer = process_pending_line(line.chomp, buffer, queue)
    end
    reader.close rescue nil
  end

  def process_pending_line(line, buffer, queue)
    if line.empty? && buffer.any?
      queue.add(buffer.join("\n"))
      return []
    end
    return buffer << line unless line.empty?

    buffer
  end

  def flush_and_close(_reader, buffer, queue)
    queue.add(buffer.join("\n")) if buffer.any?
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
