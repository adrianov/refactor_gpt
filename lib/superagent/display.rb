# frozen_string_literal: true

require 'tty-box'
require 'tty-cursor'

# Handles all output formatting and display operations for superagent.
# Color gamma: timestamps muted, body text soft (avoids straining white).
# Uses tty-box for queue banner and tty-cursor for line overwrites.
class Display
  TIMESTAMP_COLOR = :light_blue
  BODY_COLOR = :light_black
  CURSOR = TTY::Cursor

  # Optional stats shown after run time. Each [key, label, format_type]: key in stats hash, label for output.
  # format_type :duration => format_duration(value), only if value >= 1; nil => show value when present.
  OPTIONAL_RUNTIME_STAT_LINES = [
    [:waiting_elapsed, 'Waiting for input', :duration],
    [:model, 'Model', nil],
    [:current_dir, 'Current dir', nil]
  ].freeze
  THINK_CLOSE_ONLY = /\A\s*`*\s*<\/think>\s*`*\s*\z/i
  THINK_CLOSE_TAIL = /\s*`*\s*<\/think>\s*`*\s*\z/i

  def puts(*args)
    @at_start_of_line = true
    return if args.empty? || (args.first.nil? || args.first.to_s.empty?)

    ts = timestamp_str
    str = args.first.is_a?(String) ? format_with_timestamp(args[0], ts) : args[0].to_s
    out_puts(str)
    $stdout.flush
  end

  def initialize(skip_midnight_check: false)
      @at_start_of_line = true
      @current_stream_id = nil
      @has_printed_in_stream = false
      @thinking_indicator_count = 0
      @last_thinking_indicator_time = nil
      @tool_line_in_progress = false
      @skip_midnight_check = skip_midnight_check
      @output_paused = false
      @output_buffer = []
      @output_buffer_mutex = Mutex.new
      @pass_timing_display = PassTimingDisplay.new(self)
      @verification_display = VerificationDisplay.new(self)
      @outcome_display = OutcomeDisplay.new(self)
      @queue_display = QueueDisplay.new(self)
    end

  def set_output_paused(paused)
    @output_paused = paused
  end

    def output_paused
    @output_paused
  end

  def body(str)
    str.to_s.colorize(BODY_COLOR)
  end

  def format_duration(sec)
    return "0s" if sec.nil? || sec < 1
    "#{(sec / 60).to_i}m #{(sec % 60).to_i}s"
  end

  def flush_paused_output
    to_print = @output_buffer_mutex.synchronize do
      buf = @output_buffer.map { |s| normalize_utf8(s) }.join
      @output_buffer.clear
      buf
    end
    $stdout.print to_print
    $stdout.flush
  end

  def reset_after_pause
    @at_start_of_line = true
    reset_stream_tracking
  end

  # Output raw text (no timestamp) through the display so it is buffered when output is paused.
  # Optional color: symbol (e.g. :yellow) applied to each line.
  def output_raw(str, color: nil)
    return if str.to_s.empty?

    str.to_s.each_line do |line|
      out_puts color ? line.chomp.to_s.public_send(color) : line.chomp
    end
    $stdout.flush unless @output_paused
  end

    def check_late_night_reminder
      return if @skip_midnight_check
      
      now = Time.now
      hour = now.hour
      minute = now.min

      is_late_night = (hour == 23 && minute >= 30) || (hour >= 0 && hour < 6)
      return unless is_late_night

      messages = [
        "🌙 It's getting late! Your code will still be here tomorrow, and you'll tackle it with fresh eyes.",
        "⏰ Late night coding session! Remember, a well-rested mind writes better code. Tomorrow will be productive!",
        "🌆 The clock says it's time to wind down. Your future self will thank you for getting some rest.",
        "💤 It's past bedtime! Your code isn't going anywhere, but your energy is. Rest up for an amazing day!",
        "🌃 Late night warrior! Dedication is admirable, but remember that tomorrow you'll be even more productive.",
        "⭐ Burning the midnight oil? That's dedication! But even the best developers need sleep. Rest up!",
        "🌙 Late night coding is impressive, but so is a good night's sleep. Your code will be waiting for you."
      ]

      message = messages.sample
      out_puts ''
      puts message.yellow
      out_puts ''
      exit 0
    end

    # Prints one stream line of assistant text. Agent sends full lines (one JSON per line).
    def print_assistant_text(text, stream_id: nil)
      stripped = assistant_text_to_print(text)
      return if stripped.nil? || stripped.empty?

      clear_thinking_indicator
      ensure_timestamp(is_new_stream: apply_new_stream(stream_id))
      out_print body(stripped)
      out_puts '' unless stripped.end_with?("\n")
      @at_start_of_line = stripped.end_with?("\n")
      @has_printed_in_stream = true
      $stdout.flush
    end

    def assistant_text_to_print(text)
      return nil if text.nil? || text.to_s.empty?
      return nil if text.to_s.strip.gsub(/\p{C}+/, '').match?(THINK_CLOSE_ONLY)

      stripped = text.to_s.gsub(/\p{C}+/, '').sub(THINK_CLOSE_TAIL, '')
      stripped.empty? ? nil : stripped
    end

    def flush_assistant_text_buffer
      clear_thinking_indicator
      return if @at_start_of_line

      out_puts ''
      @at_start_of_line = true
      $stdout.flush
    end

    # Ensure newline after think block ends so next line (e.g. tool call) does not run on (regression fix).
    def ensure_newline_after_think_close
      flush_assistant_text_buffer
    end

    # Applies display for one stream line: show thinking indicator or assistant text when not think-close-only;
    # ensure newline once when line is think-close-only or has trailing think-close.
    def apply_stream_line_display(type, text, stream_id, think_close_only:, trailing_think_close:, passthrough:)
      unless think_close_only
        show = !passthrough
        case type
        when 'thinking' then print_thinking_indicator if show
        when 'assistant', nil then print_assistant_text(text, stream_id: stream_id) if show
        end
      end
      ensure_newline_after_think_close if think_close_only || trailing_think_close
    end

    def reset_stream_tracking
      @current_stream_id = nil
      @has_printed_in_stream = false
      @thinking_indicator_count = 0
      @last_thinking_indicator_time = nil
      @tool_line_in_progress = false
    end

    def print_thinking_indicator
      now = Time.now
      if @last_thinking_indicator_time.nil? || (now - @last_thinking_indicator_time) >= 0.5
        @thinking_indicator_count = (@thinking_indicator_count || 0) + 1
        indicator = case (@thinking_indicator_count % 4)
                    when 0 then '⠋'
                    when 1 then '⠙'
                    when 2 then '⠹'
                    else '⠸'
                    end
        out_print "\r#{timestamp_str}#{indicator.colorize(:light_black)}"
        $stdout.flush
        @last_thinking_indicator_time = now
      end
    end

    def clear_thinking_indicator
      return unless @thinking_indicator_count && @thinking_indicator_count > 0
      out_print CURSOR.clear_line
      @thinking_indicator_count = 0
      @last_thinking_indicator_time = nil
    end

    def display_git_status
      return unless git_repo?

      status = `git status --short 2>&1`.strip
      return if status.empty?

      puts 'Git status:'.cyan
      status.each_line { |line| out_puts body("  #{line.chomp}") }
      out_puts ''
    end

    def display_session_description(description)
      return unless description && !description.to_s.strip.empty?

      out_puts ''
      puts "Session: #{description}".cyan
      out_puts ''
    end

    # Shows session start: "Superagent:", session type (continuation/new + tags), full request text, then git status.
    # Request is output raw (no timestamp per line) so lines are not squished.
    def display_start_message(req, continuation = false, tags = [])
      puts "\nSuperagent:".cyan
      @queue_display.display_session_type(continuation, tags)
      output_raw(req.to_s, color: :yellow)
      out_puts ''
      display_git_status
    end

    def display_pending_hint
      out_puts ''
      box = TTY::Box.frame(
        "📥 Interactive Queue is active while agent runs.",
        'Press Enter to add a new request.',
        width: 58,
        padding: [0, 1],
        border: :light
      )
      $stdout.print box
      $stdout.puts ''
      $stdout.flush
    end

    # Lists queued requests; shows running request preview if any.
    def display_pending_list(requests, current_request: nil)
      @queue_display.display_pending_list(requests, current_request: current_request)
    end

    # Single-line preview for queue/running: first line, truncated to RequestHistoryFormatter::QUEUE_PREVIEW_LEN.
    def pending_request_preview(text)
      @queue_display.pending_request_preview(text)
    end

    def display_done_requests_recap(outcomes, queued: nil)
      @outcome_display.display_done_requests_recap(outcomes, queued: queued)
    end

    def display_attempt_header(model, idx, total)
      puts "--- Attempt #{idx + 1}/#{total}: #{model} ---".blue
      out_puts ''
    end

    def display_verification_result(verified, desc, context = '', call_failed: false, raw_recap: nil)
      @verification_display.display_verification_result(
        verified, desc, context, call_failed: call_failed, raw_recap: raw_recap
      )
    end

    def display_agent_call_result(success, tools_count = 0)
      prefix = success ? '✔ Agent call' : '✗ Agent call'
      suffix = success ? ": success (#{tools_count} tools)" : ': failed'
      puts "#{prefix}#{suffix}".send(success ? :green : :yellow)
      out_puts ''
    end

    # stats: :start_time, :active_elapsed, :waiting_elapsed; optional keys in OPTIONAL_RUNTIME_STAT_LINES.
    def display_total_runtime(stats)
      return unless stats && stats[:start_time]

      active = stats[:active_elapsed]
      active = Time.now - stats[:start_time] if active.nil?
      puts "Run time: #{format_duration(active)}".cyan
      print_optional_runtime_stats(stats)
    end

    def print_optional_runtime_stats(stats)
      OPTIONAL_RUNTIME_STAT_LINES.each do |key, label, format_type|
        value = stats[key]
        next if value.nil?
        if format_type == :duration
          next unless value >= 1
          puts "#{label}: #{format_duration(value)}".cyan
        else
          next unless value
          puts "#{label}: #{value}".cyan
        end
      end
    end

    def display_agent_failure(output = nil, reason = nil)
      msg = failure_reason_message(output, reason)
      puts "Agent failed: #{msg}. Next...".yellow
      if output && !output.to_s.strip.empty?
        out_puts ''
        out_puts 'Agent output:'.yellow
        output.each_line { |line| out_puts body("  #{line.chomp}") }
      end
      out_puts ''
    end

    def failure_reason_message(output, reason)
      if output.nil? || output.to_s.strip.empty?
        'no response (retryable, will retry up to 5 times)'
      elsif reason == :unrecoverable
        'backend error (not retryable)'
      elsif reason == :recoverable
        'connection/network error (retryable, will retry up to 5 times)'
      else
        first_line = (first = output.to_s.strip.lines.first) && first.to_s.strip
        first_line && first_line.length <= 80 ? first_line : 'see output below'
      end
    end

    def display_all_attempts_failed(original_request = nil)
      puts 'All attempts failed.'.red
      return if original_request.nil? || original_request.to_s.strip.empty?

      preview = RequestPreparer.normalized_request_text(original_request).lines.first(5).join.rstrip
      puts "Original query: #{preview}".yellow
    end

    def display_tool_call(tool_call_info)
      return unless tool_call_info && tool_call_info[:name]

      func_name = tool_call_info[:name]
      subtype = tool_call_info[:subtype]
      formatted_args = tool_call_formatter.format_args(tool_call_info[:arguments])

      tool_part = build_tool_part(func_name, subtype, formatted_args)
      print_tool_line(tool_part, subtype)
    end

    def build_tool_part(func_name, subtype, formatted_args)
      status_icon = get_status_icon(subtype)
      status_color = get_status_color(subtype)
      tool_name_color = :light_blue
      
      icon_part = "#{status_icon} ".colorize(status_color)
      name_part = "#{func_name}".colorize(tool_name_color)
      
      return icon_part + name_part unless formatted_args
      
      args_part = formatted_args.colorize(:light_black)
      icon_part + name_part + "(".colorize(:light_black) + args_part + ")".colorize(:light_black)
    end

    def get_status_icon(subtype)
      case subtype
      when 'started' then '▶'
      when 'completed' then '✓'
      else '🔧'
      end
    end

    def get_status_color(subtype)
      case subtype
      when 'completed' then :green
      when 'started' then :cyan
      else :yellow
      end
    end

    def format_tool_call_args(args)
      tool_call_formatter.format_args(args)
    end

    def tool_call_formatter
      @tool_call_formatter ||= ToolCallFormatter.new
    end

    def print_tool_line(tool_part, subtype)
      line = tool_part.to_s
      if subtype == 'started'
        print_tool_line_started(line)
        @tool_line_in_progress = true
        return
      end

      if subtype == 'completed' && @tool_line_in_progress
        overwrite_line_with_timestamp(line)
        @tool_line_in_progress = false
        return
      end

      puts line
    end

    def git_repo?
      system("git rev-parse --is-inside-work-tree > #{File::NULL} 2>&1")
    end

    def update_git_status
      return unless git_repo?

      puts 'Updating git status...'.cyan
      system("git fetch > #{File::NULL} 2>&1")
      status_output = `git status 2>&1`
      if $?.success?
        status_output.to_s.strip.each_line { |line| out_puts body(line.chomp) }
      else
        puts 'Warning: Failed to get git status'.yellow
      end
      out_puts ''
    end

    # Returns true if a git repo was initialized in this run, false otherwise.
    def suggest_git_init
      return false if git_repo?

      do_init = $stdin.tty? ? ask_user_to_init_git : (puts 'Running: git init'.green; true)
      return false unless do_init

      run_git_init
    end

    def ask_user_to_init_git
      out_puts ''
      puts '💡 Suggestion: Initialize a git repository for better tracking and verification.'.yellow
      out_puts ''
      print_git_init_advantages
      puts 'Initialize git repository? (y/N)'.colorize(BODY_COLOR)
      answer = PromptReader.read_line('', downcase: true)
      return true if answer == 'y'

      puts 'Skipping git initialization.'.yellow
      out_puts ''
      false
    end

    def print_git_init_advantages
      puts 'Advantages:'.cyan
      %w[
        Automatic\ change\ tracking\ -\ see\ exactly\ what\ was\ modified
        Faster\ verification\ -\ uses\ git\ diff\ instead\ of\ reading\ all\ files
        Better\ context\ for\ AI\ -\ only\ changed\ code\ is\ analyzed
        Easy\ rollback\ -\ revert\ changes\ if\ needed
        Version\ history\ -\ track\ your\ code\ evolution
      ].each { |line| out_puts body("  • #{line}") }
      out_puts ''
    end

    def run_git_init
      success = system('git init')
      if success
        puts 'Git repository initialized successfully.'.green
        out_puts ''
      else
        puts 'Failed to initialize git repository.'.yellow
        out_puts ''
      end
      success
    end

    def display_pass_timing(pass_timing)
      @pass_timing_display.display_pass_timing(pass_timing)
    end

    def display_feature_timing(pass_timings, feature_start_time)
      @pass_timing_display.display_feature_timing(pass_timings, feature_start_time)
    end

    def display_passes_recap(pass_timings)
      @pass_timing_display.display_passes_recap(pass_timings)
    end

    def display_single_pass_recap(pass)
      @pass_timing_display.display_single_pass_recap(pass)
    end

    def display_pass_detail(label, time, color: :light_black)
      @pass_timing_display.display_pass_detail(label, time, color: color)
    end

    def out_print(str)
      if @output_paused
        @output_buffer_mutex.synchronize { @output_buffer << str.to_s }
        return
      end
      $stdout.print str
    end

    def out_puts(str = '')
      s = str.to_s.end_with?("\n") ? str.to_s : "#{str}\n"
      if @output_paused
        @output_buffer_mutex.synchronize { @output_buffer << s }
        return
      end
      $stdout.print s
    end

    private

    def normalize_utf8(str)
      s = str.to_s
      s = s.dup.force_encoding(Encoding::UTF_8) unless s.encoding == Encoding::UTF_8
      s.valid_encoding? ? s : s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    end

    def apply_new_stream(stream_id)
      is_new = stream_id && stream_id != @current_stream_id
      if is_new
        @current_stream_id = stream_id
        @has_printed_in_stream = false
        out_puts '' unless @at_start_of_line
      end
      is_new
    end

    def timestamp_str
      Time.now.strftime("[%H:%M:%S] ").colorize(TIMESTAMP_COLOR)
    end

    def format_with_timestamp(text, ts)
      if text.start_with?("\e[")
        m_index = text.index('m')
        return text[0..m_index] + ts + (text[m_index + 1..-1] || '').to_s if m_index
      end
      "#{ts}#{text}"
    end

    def ensure_timestamp(is_new_stream: false)
      return unless @at_start_of_line
      return if @has_printed_in_stream && !is_new_stream

      out_print timestamp_str
      @at_start_of_line = false
    end

    def print_tool_line_started(text)
      if @tool_line_in_progress
        out_puts ''
        @at_start_of_line = true
      end
      line = "#{timestamp_str}#{body(text)}"
      out_print line
      @at_start_of_line = false
      $stdout.flush
    end

    def overwrite_line_with_timestamp(text)
      out_print "\r#{CURSOR.clear_line}"
      out_print "#{timestamp_str}#{body(text)}"
      out_puts ''
      @at_start_of_line = true
      $stdout.flush
    end

  end
