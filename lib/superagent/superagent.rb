# frozen_string_literal: true

require 'set'
require 'reline'
require_relative "display"
require_relative "request_reader"
require_relative "agent_executor"
require_relative "verification_handler"
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

  def initialize(display: Display.new, request_reader: nil, agent_executor: nil, verification_handler: nil)
    @display = display
    @request_reader = request_reader || RequestReader.new(@display)
    @agent_executor = agent_executor || AgentExecutor.new(@display)
    @verification_handler = verification_handler || VerificationHandler.new(@display, @agent_executor)
    @start_time = nil
    @current_pass = nil
    @current_model = nil
    @current_model_index = 0
    @pass_timings = []
    @feature_start_time = nil
  end

  def run(start_model_index: 0, request: nil)
    initialize_run(request)
    req = sanitize_request(request || @request_reader.read)
    @request_reader.validate(req)
    @display.display_start_message(req)

    return run_plan_mode(req) if @request_reader.plan_mode

    @feature_start_time = Time.now
    @pass_timings = []
    execute_attempts(start_model_index, req)
    handle_final_failure unless @last_attempt_success
  end

  def run_plan_mode(req)
    update_terminal_title('Planning...')
    @display.puts 'Running in plan mode...'.cyan
    $stdout.puts ''

    MODELS.each_with_index do |model, idx|
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
    MODELS[@current_model_index..-1].each_with_index do |model, relative_idx|
      idx = @current_model_index + relative_idx
      @current_pass = idx + 1
      @current_model = model
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
      break if process_model_attempt(model, req) == :success
    end
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
      @display.display_pass_timing(pass_timing)
      handle_success(desc)
      handle_final_success(req)
      @last_attempt_success = true
      return :success
    end

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
      @display.display_pass_timing(pass_timing)
      handle_success(fix_desc, 'after retry')
      handle_final_success(req)
      @last_attempt_success = true
      return :success
    end

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
    @display.display_git_status
  end

  def handle_final_success(previous_req = nil)
    update_terminal_title(true)
    CompletionNotifier.notify_completion(success: true)

    return unless $stdin.tty?

    lock_path = InstanceLock.current_lock_path
    InstanceLock.release_lock(lock_path) if lock_path

    update_terminal_title('✅ Passed')
    $stdout.puts ''
    @display.puts 'Enter the new request:'.cyan
    @display.puts '(Press Enter twice, Ctrl+D, or Ctrl+C to submit/exit)'
    $stdout.puts ''

    new_req = sanitize_request(read_next_request)
    return unless new_req && !new_req.strip.empty?

    new_lock_path = InstanceLock.acquire_lock
    unless new_lock_path
      @display.puts 'Failed to acquire instance lock. Exiting.'.red
      exit 1
    end

    analysis = analyze_request_continuation(new_req, previous_req)
    is_continuation = analysis[:continuation]
    tags = analysis[:tags]
    start_index = is_continuation ? @current_model_index : 0
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

  def analyze_request_continuation(new_req, previous_req)
    return {continuation: false, tags: []} if previous_req.nil? || new_req.nil?

    client = create_ask_client
    return {continuation: false, tags: []} unless client

    prompt = build_continuation_analysis_prompt(new_req, previous_req)
    response = query_ask_client(client, prompt)
    parse_continuation_response(response)
  rescue StandardError => e
    @display.puts "Warning: Failed to analyze request continuation: #{e.message}".yellow
    {continuation: false, tags: []}
  end

  def create_ask_client
    return AskGeminiClient.new(progress: false) if Utility.gemini_configured?
    return AskGptClient.new if Utility.openai_configured?

    nil
  end

  def build_continuation_analysis_prompt(new_req, previous_req)
    <<~HEREDOC
      Analyze the relationship between two requests and classify the new request.

      Previous request:
      #{previous_req}

      New request:
      #{new_req}

      Tasks:
      1. Determine if the new request continues the previous work (YES) or starts a new session (NO)
      2. Identify applicable tags from: #bug, #regression, #improvement, #feature, #refactoring, #chore, #documentation, #test, #performance, #security

      Response format (required):
      CONTINUATION: YES or NO
      TAGS: comma-separated tags (e.g., #bug, #improvement) or NONE

      Examples:
      - "fix login error" → CONTINUATION: NO, TAGS: #bug
      - "also add email validation" → CONTINUATION: YES, TAGS: #feature
      - "optimize database queries" → CONTINUATION: NO, TAGS: #improvement, #performance
      - "refactor user service" → CONTINUATION: NO, TAGS: #refactoring
    HEREDOC
  end

  def query_ask_client(client, prompt)
    if client.is_a?(AskGeminiClient)
      client.ask([{role: "user", content: prompt}], title: nil)
    else
      system_msg = "You are a request analyzer. Provide concise, structured responses."
      messages = [
        {role: "system", content: system_msg},
        {role: "user", content: prompt}
      ]
      client.ask(messages, title: nil)
    end
  end

  def parse_continuation_response(response)
    return {continuation: false, tags: []} unless response

    continuation_match = response.match(/CONTINUATION:\s*(YES|NO)/i)
    tags_match = response.match(/TAGS:\s*(.+?)(?:\n|$)/i)

    continuation = continuation_match && continuation_match[1].upcase == "YES"
    tags_text = tags_match ? tags_match[1].strip : ""
    tags = extract_tags(tags_text)

    {continuation: continuation, tags: tags}
  end

  def extract_tags(tags_text)
    return [] if tags_text.empty? || tags_text.upcase == "NONE"

    tags_text.split(",").map(&:strip).reject(&:empty?).select { |tag| tag.start_with?("#") }
  end

  def sanitize_request(req)
    return req if req.nil?

    cleaned = req.gsub(NON_INTERACTIVE_NOTICE, "\n").strip
    cleaned.gsub(/\n{3,}/, "\n\n")
  end
end
