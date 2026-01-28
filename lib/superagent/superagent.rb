# frozen_string_literal: true

require 'set'
require 'reline'
require_relative "display"
require_relative "request_reader"
require_relative "agent_executor"
require_relative "verification_handler"
require_relative "../completion_notifier"
require_relative "../instance_lock"

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
  end

  def run(start_model_index: 0, request: nil)
    initialize_run(request)
    req = sanitize_request(request || @request_reader.read)
    @request_reader.validate(req)
    @display.display_start_message(req)

    return run_plan_mode(req) if @request_reader.plan_mode

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

      success, output = @agent_executor.run(model, req)
      unless success
        @display.display_agent_failure(output)
        next
      end

      break if process_model_attempt(model, req) == :success
    end
  end

  def process_model_attempt(model, req)
    update_terminal_title("Verifying: #{model}")
    verified, desc = @verification_handler.run_verification(model, req)
    $stdout.puts ''

    if verified
      handle_success(desc)
      handle_final_success(req)
      @last_attempt_success = true
      return :success
    end

    @display.display_verification_result(false, desc)
    $stdout.puts ''

    update_terminal_title("Retrying: #{model}")
    verified, fix_desc = @verification_handler.retry_with_fix(model, req)
    $stdout.puts ''

    if verified
      handle_success(fix_desc, 'after retry')
      handle_final_success(req)
      @last_attempt_success = true
      return :success
    end

    @last_attempt_success = false

    @display.display_verification_result(false, fix_desc, 'after retry')
    $stdout.puts ''
    :continue
  end


  def handle_success(desc, context = '')
    @display.display_verification_result(true, desc, context)
    @display.display_total_runtime(@start_time)
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

    is_fix_or_improvement = detect_fix_or_improvement(new_req, previous_req)
    start_index = is_fix_or_improvement ? @current_model_index : 0
    start_index = [[start_index, 0].max, MODELS.size - 1].min

    $stdout.puts ''
    @display.puts "Starting #{is_fix_or_improvement ? 'continuation' : 'new request'} from #{MODELS[start_index]}...".yellow
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

  def detect_fix_or_improvement(new_req, previous_req)
    return false if previous_req.nil? || new_req.nil?

    new_lower = new_req.downcase.strip
    prev_lower = previous_req.downcase.strip

    return true if check_keywords(new_lower)

    trigram_intersection = count_trigram_intersection(new_lower, prev_lower)
    return true if trigram_intersection >= 5

    word_similarity = calculate_word_similarity(new_lower, prev_lower)
    return true if word_similarity > 0.35

    combined_score = (trigram_intersection * 0.15) + (word_similarity * 0.85)
    combined_score > 0.25
  end

  def extract_trigrams(text)
    return [] if text.length < 3

    (0..text.length - 3).map { |i| text[i, 3] }.to_set
  end

  def count_trigram_intersection(text1, text2)
    trigrams1 = extract_trigrams(text1)
    trigrams2 = extract_trigrams(text2)
    (trigrams1 & trigrams2).size
  end

  def calculate_word_similarity(text1, text2)
    words1 = normalize_words(text1)
    words2 = normalize_words(text2)
    return 0.0 if words1.empty? || words2.empty?

    common_words = words1 & words2
    union_words = (words1 | words2).size
    return 0.0 if union_words.zero?

    jaccard = common_words.size.to_f / union_words

    word_order_similarity = calculate_word_order_similarity(words1, words2)
    (jaccard * 0.7) + (word_order_similarity * 0.3)
  end

  def normalize_words(text)
    text.split(/\s+/).reject { |w| w.length < 2 }.map(&:downcase).to_set
  end

  def calculate_word_order_similarity(words1, words2)
    words1_arr = words1.to_a
    words2_arr = words2.to_a
    common = words1 & words2
    return 0.0 if common.empty?

    positions1 = build_word_positions(words1_arr, common)
    positions2 = build_word_positions(words2_arr, common)
    return 0.0 if positions1.empty? || positions2.empty?

    max_len = [words1_arr.size, words2_arr.size].max
    calculate_average_order_similarity(common, positions1, positions2, max_len)
  end

  def calculate_average_order_similarity(common, positions1, positions2, max_len)
    total_similarity = 0.0
    count = 0

    common.each do |word|
      pos1 = positions1[word] || []
      pos2 = positions2[word] || []
      next if pos1.empty? || pos2.empty?

      min_diff = calculate_min_position_diff(pos1, pos2)
      total_similarity += 1.0 - (min_diff.to_f / max_len)
      count += 1
    end

    count.zero? ? 0.0 : total_similarity / count
  end

  def calculate_min_position_diff(pos1, pos2)
    pos1.map { |p1| pos2.map { |p2| (p1 - p2).abs }.min }.min
  end

  def build_word_positions(words, common_words)
    positions = {}
    words.each_with_index do |word, idx|
      next unless common_words.include?(word)

      positions[word] ||= []
      positions[word] << idx
    end
    positions
  end

  def check_keywords(new_lower)
    fix_keywords = %w[fix bug error issue problem broken wrong incorrect failed failure]
    improvement_keywords = %w[improve enhance better optimize refine adjust modify update change]
    continuation_keywords = %w[also and continue add more]

    is_fix = fix_keywords.any? { |keyword| new_lower.include?(keyword) }
    is_improvement = improvement_keywords.any? { |keyword| new_lower.include?(keyword) }
    is_continuation = continuation_keywords.any? { |keyword|
      new_lower.start_with?(keyword) || new_lower.match?(/\b#{keyword}\s/) }

    is_fix || is_improvement || is_continuation
  end

  def sanitize_request(req)
    return req if req.nil?

    cleaned = req.gsub(NON_INTERACTIVE_NOTICE, "\n").strip
    cleaned.gsub(/\n{3,}/, "\n\n")
  end
end
