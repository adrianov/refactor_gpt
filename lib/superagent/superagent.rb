# frozen_string_literal: true

require 'set'
require 'reline'
require_relative "display"
require_relative "request_reader"
require_relative "agent_executor"
require_relative "verification_handler"
require_relative "session_tracker"
require_relative "../completion_notifier"
require_relative "../instance_lock"
require_relative "../../ask_gpt"

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

  def initialize(display: Display.new, request_reader: nil, agent_executor: nil, verification_handler: nil, 
session_tracker: nil)
    @display = display
    @request_reader = request_reader || RequestReader.new(@display)
    @agent_executor = agent_executor || AgentExecutor.new(@display)
    @verification_handler = verification_handler || VerificationHandler.new(@display, @agent_executor)
    @session_tracker = session_tracker || SessionTracker.new(@display)
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
    @bug_count_per_model = {}
  end

  def run(start_model_index: 0, request: nil)
    initialize_run(request)
    raw_req = request || @request_reader.read
    model_index_from_request = extract_model_index(raw_req)
    start_model_index = model_index_from_request if model_index_from_request
    req = sanitize_request(raw_req)
    @request_reader.validate(req)
    @current_request = req
    
    analyze_session_continuation(req)
    @display.display_start_message(req, @session_continuation, @session_tags)

    return run_plan_mode(req, start_model_index) if @request_reader.plan_mode

    @feature_start_time = Time.now
    @pass_timings = []
    execute_attempts(start_model_index, req)
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
    # Only reset bug count for new sessions, not continuations
    @bug_count_per_model = {} unless @session_continuation
    highest_index_reached = start_index
    MODELS[@current_model_index..-1].each_with_index do |model, relative_idx|
      idx = @current_model_index + relative_idx
      @current_pass = idx + 1
      @current_model = model
      # Track the highest model index we've reached in this session (even if skipped)
      highest_index_reached = idx if idx > highest_index_reached
      
      # Skip model if it already has 2 bugs in this session
      if @bug_count_per_model[model] && @bug_count_per_model[model] >= 2
        next
      end
      
      update_terminal_title("Attempting: #{model}")
      @display.display_attempt_header(model, idx, MODELS.size)

      implementation_start = Time.now
      success, output = @agent_executor.run(model, req)
      implementation_time = Time.now - implementation_start
      
      unless success
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
        next
      end

      # Store implementation time for this pass
      @current_implementation_time = implementation_time
      result = process_model_attempt(model, req)
      break if result == :success
    end
    # Update current model index to the highest we've reached
    @current_model_index = highest_index_reached
  end

  def process_model_attempt(model, req)
    pass_start_time = Time.now
    pass_timing = {
      pass: @current_pass,
      model: model,
      implementation_time: @current_implementation_time,
      review_time: 0,
      fix_time: 0,
      total_time: 0
    }

    update_terminal_title("Verifying: #{model}")
    verified, desc, review_time = @verification_handler.run_verification(model, req)
    pass_timing[:review_time] = review_time
    $stdout.puts ''

    if verified
      pass_timing[:total_time] = Time.now - pass_start_time + @current_implementation_time
      @pass_timings << pass_timing
      handle_success(desc)
      handle_final_success(req)
      @last_attempt_success = true
      return :success
    end

    @bug_count_per_model[model] = (@bug_count_per_model[model] || 0) + 1
    @display.display_verification_result(false, desc)
    $stdout.puts ''

    update_terminal_title("Retrying: #{model}")
    fix_start = Time.now
    verified, fix_desc, fix_review_time = @verification_handler.retry_with_fix(model, req)
    pass_timing[:fix_time] = Time.now - fix_start - (fix_review_time || 0)
    pass_timing[:review_time] += (fix_review_time || 0)
    $stdout.puts ''

    if verified
      pass_timing[:total_time] = Time.now - pass_start_time + @current_implementation_time
      @pass_timings << pass_timing
      handle_success(fix_desc, 'after retry')
      handle_final_success(req)
      @last_attempt_success = true
      return :success
    end

    @bug_count_per_model[model] = (@bug_count_per_model[model] || 0) + 1
    @last_attempt_success = false

    @display.display_verification_result(false, fix_desc, 'after retry')
    $stdout.puts ''
    pass_timing[:total_time] = Time.now - pass_start_time + @current_implementation_time
    @pass_timings << pass_timing
    @display.display_pass_timing(pass_timing)
    :continue
  end


  def handle_success(desc, context = '')
    @display.display_verification_result(true, desc, context)
    @display.display_total_runtime(@start_time)
    @display.display_feature_timing(@pass_timings, @feature_start_time) if @feature_start_time
    @display.display_passes_recap(@pass_timings)
    @display.display_git_diff
    @display.display_git_status
    @display.display_session_description(@session_description) if @session_description
  end

  def handle_final_success(previous_req = nil)
    update_terminal_title(true)
    CompletionNotifier.notify_completion(success: true)
    
    # Save current session with the request that was just processed
    current_req = previous_req || @current_request
    save_current_session(current_req) if current_req

    return unless $stdin.tty?

    lock_path = InstanceLock.current_lock_path
    InstanceLock.release_lock(lock_path) if lock_path

    update_terminal_title('✅ Passed')
    $stdout.puts ''
    @display.puts 'Enter the new request:'.cyan
    @display.puts '(Press Enter twice, Ctrl+D, or Ctrl+C to submit/exit)'
    $stdout.puts ''

    raw_new_req = read_next_request
    return unless raw_new_req && !raw_new_req.strip.empty?

    model_index_from_request = extract_model_index(raw_new_req)
    new_req = sanitize_request(raw_new_req)
    return unless new_req && !new_req.strip.empty?

    new_lock_path = InstanceLock.acquire_lock
    unless new_lock_path
      @display.puts 'Failed to acquire instance lock. Exiting.'.red
      exit 1
    end

    analysis = @session_tracker.analyze_continuation(new_req, previous_req ? {request: previous_req} : nil)
    is_continuation = analysis[:continuation]
    tags = analysis[:tags]
    if is_continuation
      # In continued session: never reset to previous model, always move forward
      start_index = if model_index_from_request
                      [model_index_from_request, @current_model_index].max
                    else
                      @current_model_index
                    end
    else
      # New session: start from first model in queue
      start_index = model_index_from_request || 0
    end
    start_index = [[start_index, 0].max, MODELS.size - 1].min

    $stdout.puts ''
    tag_display = tags.empty? ? '' : " [#{tags.join(', ')}]"
    request_type = is_continuation ? 'continuation' : 'new request'
    model_name = MODELS[start_index]
    @display.puts "Starting #{request_type}#{tag_display} from #{model_name}...".yellow
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
    @display.puts 'Interrupted. Exiting.'.yellow
    exit 0
  rescue StandardError => e
    @display.puts "Error reading input: #{e.message}".yellow
    return nil
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

  def save_current_session(req)
    @session_tracker.save_session(req, @session_description, @session_tags, @session_continuation)
  end

  def sanitize_request(req)
    return req if req.nil?

    cleaned = req.gsub(NON_INTERACTIVE_NOTICE, "\n").strip
    cleaned = remove_model_mentions(cleaned)
    cleaned.gsub(/\n{3,}/, "\n\n")
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
end
