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

  def puts(*args)
    @at_start_of_line = true
    return if args.empty? || args.first.to_s.strip.empty?

    ts = timestamp_str
    str = args.first.is_a?(String) ? format_with_timestamp(args[0], ts) : args[0].to_s
    out_puts(str)
    $stdout.flush
  end

  def initialize(skip_midnight_check: false)
      @text_buffer = ''
      @at_start_of_line = true
      @current_stream_id = nil
      @has_printed_in_stream = false
      @last_printed_line = nil
      @thinking_indicator_count = 0
      @last_thinking_indicator_time = nil
      @tool_line_in_progress = false
      @skip_midnight_check = skip_midnight_check
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

    def print_word(text, stream_id: nil)
      return if text.nil? || text.to_s.empty?

      clear_thinking_indicator

      @text_buffer ||= ''
      @at_start_of_line ||= true

      is_new_stream = stream_id && stream_id != @current_stream_id
      if is_new_stream
        @current_stream_id = stream_id
        @has_printed_in_stream = false
        out_puts '' unless @text_buffer.empty?
      end

      @text_buffer += text.to_s
      process_complete_lines(is_new_stream: is_new_stream)

      if @text_buffer.length > 200 && !@text_buffer.include?("\n")
        ensure_timestamp(is_new_stream: is_new_stream) if @at_start_of_line
        out_print body(@text_buffer)
        @text_buffer = ''
        @at_start_of_line = false
        @has_printed_in_stream = true
        $stdout.flush
      end
    end

    def flush_word_buffer
      clear_thinking_indicator
      return if @text_buffer.nil? || @text_buffer.empty?

      @text_buffer ||= ''
      @at_start_of_line ||= true
      @text_buffer = @text_buffer.sub(/\n{2,}\z/, "\n")
      process_complete_lines

      unless @text_buffer.to_s.strip.empty?
        ensure_timestamp if @at_start_of_line
        out_print body(@text_buffer)
        out_puts '' unless @text_buffer.end_with?("\n")
        @text_buffer = ''
        @at_start_of_line = true
        @has_printed_in_stream = true
        $stdout.flush
      end
    end

    def reset_stream_tracking
      @current_stream_id = nil
      @has_printed_in_stream = false
      @last_printed_line = nil
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

    def display_git_diff
      return unless git_repo?

      system("git diff")
      out_puts ''
    end

    def display_session_description(description)
      return unless description && !description.to_s.strip.empty?

      out_puts ''
      puts "Session: #{description}".cyan
      out_puts ''
    end

    def display_start_message(req, continuation = false, tags = [])
      puts "\nSuperagent:".cyan
      display_session_type(continuation, tags)
      puts req.yellow
      out_puts ''
      display_git_status
    end

    def display_pending_hint
      out_puts ''
      box = TTY::Box.frame(
        "📥 Interactive Queue is active while agent runs.",
        'Type request below, press Enter twice to queue.',
        width: 58,
        padding: [0, 1],
        border: :light
      )
      out_print box
      out_puts ''
    end

    def display_pending_list(requests)
      return if requests.nil? || requests.empty?

      puts "Using #{requests.size} queued request(s):".cyan
      requests.each_with_index { |r, i| out_puts body("  #{i + 1}. #{r.lines.first&.chomp}") }
      out_puts ''
    end

    def display_session_type(continuation, tags)
      if continuation
        tag_display = tags.empty? ? '' : " [#{tags.join(', ')}]"
        puts "↻ Continuing previous session#{tag_display}".light_blue
        puts 'Step: Resuming previous session'.cyan
        out_puts ''
      elsif tags.any?
        puts "🆕 New session [#{tags.join(', ')}]".light_blue
        out_puts ''
      end
    end

    def display_attempt_header(model, idx, total)
      puts "--- Attempt #{idx + 1}/#{total}: #{model} ---".blue
      out_puts ''
    end

    def display_verification_result(verified, desc, context = '', call_failed: false)
      prefix = if call_failed
                 'Verification call did not complete'
               else
                 verified ? '✔ Passed' : '✗ Failed'
               end
      suffix = context.empty? ? '' : " #{context}"

      if desc && !desc.empty?
        puts "#{prefix}#{suffix}:".send(verified ? :green : :yellow)
        desc.each_line { |line| out_puts body("  #{line.chomp}") }
      elsif verified
        puts "#{prefix}#{suffix}! Success.".send(:green)
      else
        puts "#{prefix}#{suffix}! #{context.empty? ? 'Retrying...' : 'Next...'}".send(:yellow)
      end
    end

    def display_agent_call_result(success, tools_count = 0)
      prefix = success ? '✔ Agent call' : '✗ Agent call'
      suffix = success ? ": success (#{tools_count} tools)" : ': failed'
      puts "#{prefix}#{suffix}".send(success ? :green : :yellow)
      out_puts ''
    end

    def display_total_runtime(start_time, active_elapsed: nil, waiting_elapsed: nil)
      return unless start_time

      active = active_elapsed
      active = Time.now - start_time if active.nil?
      puts "Run time: #{format_duration(active)}".cyan
      puts "Waiting for input: #{format_duration(waiting_elapsed)}".cyan if waiting_elapsed && waiting_elapsed >= 1
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
        first_line = output.to_s.strip.lines.first&.strip
        first_line && first_line.length <= 80 ? first_line : 'see output below'
      end
    end

    def display_all_attempts_failed(original_request = nil)
      puts 'All attempts failed.'.red
      return if original_request.to_s.strip.empty?

      preview = original_request.to_s.strip.lines.first(5).join.rstrip
      puts "Original query: #{preview}".yellow
    end

    def display_tool_call(tool_call_info)
      return unless tool_call_info && tool_call_info[:name]

      func_name = tool_call_info[:name]
      subtype = tool_call_info[:subtype]
      formatted_args = format_tool_call_args(tool_call_info[:arguments])

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
      return nil unless args
      return format_hash_args(args) if args.is_a?(Hash)
      return format_string_args(args) if args.is_a?(String) && !args.empty?
      
      nil
    end

    def format_hash_args(args)
      filtered_args = args.reject { |k, _| %w[explanation toolCallId].include?(k) }
      return nil if filtered_args.empty?
      
      formatted_parts = filtered_args.map { |k, v| "#{k}: #{format_arg_value(v)}" }
      args_str = formatted_parts.join(', ')
      truncate_string(args_str, 120)
    end

    def format_string_args(args)
      truncate_string(args, 120)
    end

    def truncate_string(str, max_length)
      return str if str.length <= max_length
      "#{str[0..(max_length - 4)]}..."
    end

    def format_arg_value(v)
      case v
      when String
        format_string_value(v)
      when Hash, Array
        format_inspect_value(v)
      else
        v.inspect
      end
    end

    def format_string_value(v)
      return v if v.length <= 50
      return format_url_value(v) if v.match?(%r{\Ahttps?://})
      return format_path_value(v) if v.include?('/') && v.length > 40

      "#{v[0..47]}..."
    end

    def format_url_value(v)
      m = v.match(%r{\A(https?://[^/]+)(/.*)?\z})
      return v if !m || v.length <= 80

      origin = m[1]
      path = m[2]
      return origin if path.nil? || path.empty?
      return v if (origin.length + path.length) <= 80

      "#{origin}/...#{url_path_suffix(path)}"
    end

    def url_path_suffix(path)
      filename = path.split('/').last
      return '' if filename.nil? || filename.empty?
      filename.length > 30 ? filename[-27..] : filename
    end

    def format_path_value(v)
      parts = v.split('/')
      filename = parts.last
      
      return "#{parts[0..-2].join('/')}/...#{filename[-27..-1]}" if filename.length > 30
      return "#{parts[0]}/...#{parts[-2]}/#{filename}" if parts.length > 3
      
      v.length > 50 ? "#{v[0..47]}..." : v
    end

    def format_inspect_value(v)
      inspected = v.inspect
      inspected.length > 50 ? "#{inspected[0..47]}..." : inspected
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

    def suggest_git_init
      return if git_repo?

      out_puts ''
      puts '💡 Suggestion: Initialize a git repository for better tracking and verification.'.yellow
      out_puts ''
      puts 'Advantages:'.cyan
      out_puts body('  • Automatic change tracking - see exactly what was modified')
      out_puts body('  • Faster verification - uses git diff instead of reading all files')
      out_puts body('  • Better context for AI - only changed code is analyzed')
      out_puts body('  • Easy rollback - revert changes if needed')
      out_puts body('  • Version history - track your code evolution')
      out_puts ''

      puts 'Initialize git repository? (y/N)'.colorize(BODY_COLOR)
      answer = $stdin.gets.to_s.chomp.downcase

      if answer == 'y'
        puts 'Running: git init'.green
        success = system('git init')
        if success
          puts 'Git repository initialized successfully.'.green
        else
          puts 'Failed to initialize git repository.'.yellow
        end
        out_puts ''
      else
        puts 'Skipping git initialization.'.yellow
        out_puts ''
      end
    end

    def display_pass_timing(pass_timing)
      return unless pass_timing

      out_puts ''
      puts "Pass #{pass_timing[:pass]} timing:".cyan
      
      display_timing_item("Implementation", pass_timing[:implementation_time], :light_blue)
      display_timing_item("Review", pass_timing[:review_time], :light_blue)
      display_timing_item("Fix", pass_timing[:fix_time], :light_blue)
      display_timing_item("Total", pass_timing[:total_time], :cyan)
      
      out_puts ''
    end

    def display_timing_item(label, time, color)
      return unless time
      puts "  #{label}: #{format_duration(time)}".send(color)
    end

    def display_feature_timing(pass_timings, feature_start_time)
      return unless feature_start_time && pass_timings && !pass_timings.empty?

      total_feature_time = Time.now - feature_start_time
      
      total_implementation = pass_timings.sum { |p| p[:implementation_time] || 0 }
      total_review = pass_timings.sum { |p| p[:review_time] || 0 }
      total_fix = pass_timings.sum { |p| p[:fix_time] || 0 }
      
      out_puts ''
      puts "Feature/Bugfix/Chore timing:".cyan
      puts "  Implementation: #{format_duration(total_implementation)}".light_blue
      puts "  Review: #{format_duration(total_review)}".light_blue
      puts "  Fix: #{format_duration(total_fix)}".light_blue
      puts "  Total: #{format_duration(total_feature_time)}".cyan
      out_puts ''
    end

    def display_passes_recap(pass_timings)
      return unless pass_timings && !pass_timings.empty?

      out_puts ''
      puts "Models used and timings:".cyan
      pass_timings.each { |pass| display_single_pass_recap(pass) }
      out_puts ''
    end

    def display_single_pass_recap(pass)
      model = pass[:model] || 'unknown'
      pass_num = pass[:pass] || '?'
      puts "  Pass #{pass_num}: #{model}".light_blue
      
      display_pass_detail("Implementation", pass[:implementation_time])
      display_pass_detail("Review", pass[:review_time])
      display_pass_detail("Fix", pass[:fix_time])
      display_pass_detail("Total", pass[:total_time], color: :cyan)
    end

    def display_pass_detail(label, time, color: :light_black)
      return unless time && time > 0
      puts "    #{label}: #{format_duration(time)}".send(color)
    end

    def out_print(str)
      $stdout.print str
    end

    def out_puts(str = '')
      out_print(str.to_s.end_with?("\n") ? str : "#{str}\n")
    end

    private

    def timestamp_str
      Time.now.strftime("[%H:%M:%S] ").colorize(TIMESTAMP_COLOR)
    end

    def body(str)
      str.to_s.colorize(BODY_COLOR)
    end

    def format_with_timestamp(text, ts)
      if text.start_with?("\e[")
        m_index = text.index('m')
        return text[0..m_index] + ts + text[m_index + 1..-1] if m_index
      end
      "#{ts}#{text}"
    end

    def process_complete_lines(is_new_stream: false)
      return if @text_buffer.empty?

      while (newline_idx = @text_buffer.index("\n"))
        line_with_newline = @text_buffer[0..newline_idx]
        @text_buffer = @text_buffer[(newline_idx + 1)..-1] || ''

        line_content = line_with_newline.chomp
        unless line_content.empty? || line_content == @last_printed_line
          @last_printed_line = line_content
          ensure_timestamp(is_new_stream: is_new_stream)
          out_print body(line_content)
          @has_printed_in_stream = true
        end

        out_puts ''
        @at_start_of_line = true
        $stdout.flush
      end
    end

    def ensure_timestamp(is_new_stream: false)
      return unless @at_start_of_line
      return if @has_printed_in_stream && !is_new_stream

      out_print timestamp_str
      @at_start_of_line = false
    end

    def format_duration(sec)
      return "0s" if sec.nil? || sec < 1
      "#{(sec / 60).to_i}m #{(sec % 60).to_i}s"
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
