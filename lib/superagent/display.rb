# frozen_string_literal: true

# Handles all output formatting and display operations for superagent.
# Color gamma: timestamps muted, body text soft (avoids straining white).
class Display
    TIMESTAMP_COLOR = :light_blue
    BODY_COLOR = :light_black

    def puts(*args)
      @at_start_of_line = true
      return super(*args) if args.empty? || args.first.to_s.strip.empty?

      ts = timestamp_str
      if args.first.is_a?(String)
        args[0] = format_with_timestamp(args[0], ts)
      else
        super(ts)
      end
      super(*args)
      $stdout.flush
    end

    def initialize
      @text_buffer = ''
      @at_start_of_line = true
      @current_stream_id = nil
      @has_printed_in_stream = false
      @last_printed_line = nil
    end

    def check_late_night_reminder
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
      $stdout.puts ''
      puts message.yellow
      $stdout.puts ''
      exit 0
    end

    def print_word(text, stream_id: nil)
      return if text.nil? || text.empty?

      @text_buffer ||= ''
      @at_start_of_line ||= true
      @has_printed_content ||= false

      is_new_stream = stream_id && stream_id != @current_stream_id
      if is_new_stream
        @current_stream_id = stream_id
        @has_printed_in_stream = false
      end

      @text_buffer += text
      process_complete_lines(is_new_stream: is_new_stream)

      if @text_buffer.length > 200 && !@text_buffer.include?("\n")
        ensure_timestamp(is_new_stream: is_new_stream) if @at_start_of_line
        $stdout.print body(@text_buffer)
        @text_buffer = ''
        @at_start_of_line = false
        @has_printed_content = true
        @has_printed_in_stream = true
        $stdout.flush
      end
    end

    def flush_word_buffer
      return if @text_buffer.nil? || @text_buffer.empty?

      @text_buffer ||= ''
      @at_start_of_line ||= true
      @text_buffer = @text_buffer.sub(/\n{2,}\z/, "\n")
      process_complete_lines

      unless @text_buffer.strip.empty?
        ensure_timestamp if @at_start_of_line
        $stdout.print body(@text_buffer)
        $stdout.puts '' unless @text_buffer.end_with?("\n")
        @text_buffer = ''
        @at_start_of_line = true
        @has_printed_content = true
        @has_printed_in_stream = true
        $stdout.flush
      end
    end

    def reset_stream_tracking
      @current_stream_id = nil
      @has_printed_in_stream = false
      @last_printed_line = nil
    end

    def display_git_status
      return unless git_repo?

      status = `git status --short 2>&1`.strip
      return if status.empty?

      puts 'Git status:'.cyan
      status.each_line { |line| $stdout.puts body("  #{line.chomp}") }
      $stdout.puts ''
    end

    def display_git_diff
      return unless git_repo?

      system("git diff")
      $stdout.puts ''
    end

    def display_session_description(description)
      return unless description && !description.strip.empty?

      $stdout.puts ''
      puts "Session: #{description}".cyan
      $stdout.puts ''
    end

    def display_start_message(req, continuation = false, tags = [])
      puts "\nSuperagent:".cyan
      
      if continuation
        tag_display = tags.empty? ? '' : " [#{tags.join(', ')}]"
        puts "↻ Continuing previous session#{tag_display}".light_blue
        $stdout.puts ''
      elsif tags.any?
        puts "🆕 New session [#{tags.join(', ')}]".light_blue
        $stdout.puts ''
      end
      
      puts req.yellow
      $stdout.puts ''
      display_git_status
    end

    def display_attempt_header(model, idx, total)
      puts "--- Attempt #{idx + 1}/#{total}: #{model} ---".blue
      $stdout.puts ''
    end

    def display_verification_result(verified, desc, context = '')
      prefix = verified ? '✓ Passed' : '✗ Failed'
      suffix = context.empty? ? '' : " #{context}"

      if desc && !desc.empty?
        puts "#{prefix}#{suffix}:".send(verified ? :green : :yellow)
        desc.each_line { |line| $stdout.puts body("  #{line.chomp}") }
      elsif verified
        puts "#{prefix}#{suffix}! Success.".send(:green)
      else
        puts "#{prefix}#{suffix}! #{context.empty? ? 'Retrying...' : 'Next...'}".send(:yellow)
      end
    end

    def display_total_runtime(start_time)
      return unless start_time

      elapsed = Time.now - start_time
      puts "Run time: #{format_duration(elapsed)}".cyan
    end

    def display_agent_failure(output = nil)
      puts 'Agent failed. Next...'.yellow
      if output && !output.strip.empty?
        $stdout.puts ''
        $stdout.puts 'Agent output:'.yellow
        output.each_line { |line| $stdout.puts body("  #{line.chomp}") }
      end
      $stdout.puts ''
    end

    def display_all_attempts_failed
      puts 'All attempts failed.'.red
    end

    def display_tool_call(tool_call_info)
      return unless tool_call_info && tool_call_info[:name]

      func_name = tool_call_info[:name]
      args_str = format_tool_call_args(tool_call_info[:arguments])
      display_text = args_str ? "🔧 Tool: #{func_name}(#{args_str})" : "🔧 Tool: #{func_name}"
      puts display_text.cyan
    end

    def format_tool_call_args(args)
      return nil unless args

      if args.is_a?(Hash)
        args_str = args.map { |k, v| "#{k}: #{v.inspect}" }.join(', ')
        args_str.length > 100 ? args_str[0..100] + '...' : args_str
      elsif args.is_a?(String) && !args.empty?
        args.length > 100 ? args[0..100] + '...' : args
      end
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
        status_output.strip.each_line { |line| $stdout.puts body(line.chomp) }
      else
        puts 'Warning: Failed to get git status'.yellow
      end
      $stdout.puts ''
    end

    def suggest_git_init
      return if git_repo?

      $stdout.puts ''
      puts '💡 Suggestion: Initialize a git repository for better tracking and verification.'.yellow
      $stdout.puts ''
      puts 'Advantages:'.cyan
      $stdout.puts body('  • Automatic change tracking - see exactly what was modified')
      $stdout.puts body('  • Faster verification - uses git diff instead of reading all files')
      $stdout.puts body('  • Better context for AI - only changed code is analyzed')
      $stdout.puts body('  • Easy rollback - revert changes if needed')
      $stdout.puts body('  • Version history - track your code evolution')
      $stdout.puts ''

      return unless $stdin.tty?

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
        $stdout.puts ''
      else
        puts 'Skipping git initialization.'.yellow
        $stdout.puts ''
      end
    end

    def display_pass_timing(pass_timing)
      return unless pass_timing

      $stdout.puts ''
      puts "Pass #{pass_timing[:pass]} timing:".cyan
      
      if pass_timing[:implementation_time]
        puts "  Implementation: #{format_duration(pass_timing[:implementation_time])}".light_blue
      end
      
      if pass_timing[:review_time]
        puts "  Review: #{format_duration(pass_timing[:review_time])}".light_blue
      end
      
      if pass_timing[:fix_time]
        puts "  Fix: #{format_duration(pass_timing[:fix_time])}".light_blue
      end
      
      if pass_timing[:total_time]
        puts "  Total: #{format_duration(pass_timing[:total_time])}".cyan
      end
      
      $stdout.puts ''
    end

    def display_feature_timing(pass_timings, feature_start_time)
      return unless feature_start_time && pass_timings && !pass_timings.empty?

      total_feature_time = Time.now - feature_start_time
      
      total_implementation = pass_timings.sum { |p| p[:implementation_time] || 0 }
      total_review = pass_timings.sum { |p| p[:review_time] || 0 }
      total_fix = pass_timings.sum { |p| p[:fix_time] || 0 }
      
      $stdout.puts ''
      puts "Feature/Bugfix/Chore timing:".cyan
      puts "  Implementation: #{format_duration(total_implementation)}".light_blue
      puts "  Review: #{format_duration(total_review)}".light_blue
      puts "  Fix: #{format_duration(total_fix)}".light_blue
      puts "  Total: #{format_duration(total_feature_time)}".cyan
      $stdout.puts ''
    end

    def display_passes_recap(pass_timings)
      return unless pass_timings && !pass_timings.empty?

      $stdout.puts ''
      puts "Models used and timings:".cyan
      
      pass_timings.each do |pass|
        model = pass[:model] || 'unknown'
        pass_num = pass[:pass] || '?'
        
        puts "  Pass #{pass_num}: #{model}".light_blue
        
        impl_time = pass[:implementation_time] || 0
        puts "    Implementation: #{format_duration(impl_time)}".light_black if impl_time > 0
        
        review_time = pass[:review_time] || 0
        puts "    Review: #{format_duration(review_time)}".light_black if review_time > 0
        
        fix_time = pass[:fix_time] || 0
        puts "    Fix: #{format_duration(fix_time)}".light_black if fix_time > 0
        
        total_time = pass[:total_time] || 0
        puts "    Total: #{format_duration(total_time)}".cyan if total_time > 0
      end
      
      $stdout.puts ''
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
          $stdout.print body(line_content)
          @has_printed_in_stream = true
        end

        $stdout.puts ''
        @at_start_of_line = true
        @has_printed_content = true
        $stdout.flush
      end
    end

    def ensure_timestamp(is_new_stream: false)
      return unless @at_start_of_line
      return if @has_printed_in_stream && !is_new_stream

      $stdout.print timestamp_str
      @at_start_of_line = false
    end

    def format_duration(sec)
      return "0s" if sec.nil? || sec < 1
      "#{(sec / 60).to_i}m #{(sec % 60).to_i}s"
    end
  end
