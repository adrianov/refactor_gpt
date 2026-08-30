# frozen_string_literal: true

module Quality
  # Stage-state files under STATE: pending/review markers, stage progress,
  # commit markers, and the short mkdir lock used by git_commit_gpt.
  module StateStore
    def pending_file; File.join(STATE, "stop-pending-#{@session_key}"); end
    def review_flag_file(name); File.join(STATE, "stop-#{name}-#{@session_key}"); end
    def review_flag?(name); File.file?(review_flag_file(name)); end
    def stage_file; File.join(STATE, "stop-stage-#{@session_key}"); end
    def write_commit_marker(path, head, dirt, status); File.write(path, "#{head}\n#{dirt}\n#{status}\n"); end
    def finish_empty
      empty
    end
    def set_review_flag(name)
      FileUtils.mkdir_p(STATE)
      File.write(review_flag_file(name), '')
    end
    def unset_review_flags
      %w[verify scatter].each { |n| f = review_flag_file(n); File.delete(f) if File.file?(f) }
    rescue StandardError
      nil
    end
    def load_stage
      return [nil, []] unless File.file?(stage_file)

      lines = File.readlines(stage_file).map(&:chomp)
      [lines[0], lines[1..-1].to_a.reject(&:empty?)]
    end
    def save_stage(name, files = [])
      FileUtils.mkdir_p(STATE)
      File.write(stage_file, ([name] + Array(files)).join("\n") + "\n")
    end
    def clear_stage
      [stage_file, pending_file].each { |f| File.delete(f) if File.file?(f) }
      unset_review_flags
    rescue StandardError
      nil
    end
    # Repeat marker ("digest\ncount"): consecutive deliveries of an identical
    # followup message; quality.rb trips the no-progress breaker on it.
    def repeat_file; File.join(STATE, "stop-repeat-#{@session_key}"); end
    def load_repeat
      return ['', 0] unless File.file?(repeat_file)

      rows = File.readlines(repeat_file).map(&:chomp)
      [rows[0].to_s, rows[1].to_i]
    end
    def save_repeat(digest, count); File.write(repeat_file, "#{digest}\n#{count}\n"); end
    def clear_repeat; File.delete(repeat_file) if File.file?(repeat_file); rescue StandardError; nil; end
    def cleanup_state
      FileUtils.mkdir_p(STATE)
      cutoff = Time.now - 7 * 86_400
      Dir.glob(File.join(STATE, '*')).each { |f|
 (File.delete(f) if File.file?(f) && File.mtime(f) < cutoff) rescue nil }
    rescue StandardError
      nil
    end
    def acquire_lock(dir, age = LOCK_AGE)
      true if Dir.mkdir(dir)
    rescue Errno::EEXIST
      mtime = File.mtime(dir).to_i rescue 0
      return false if Time.now.to_i - mtime < age

      Dir.rmdir(dir) rescue nil
      begin
        true if Dir.mkdir(dir)
      rescue Errno::EEXIST
        false
      end
    rescue StandardError
      false
    end
    def record_commit_marker(ctx, leftover, warnings, newhead)
      own, marker, head = ctx[:own], ctx[:marker], ctx[:head]
      if own
        if !newhead.empty? && newhead != head
          write_commit_marker(marker, newhead, leftover, 'ok')
        elsif !warnings.strip.empty?
          write_commit_marker(marker, head, leftover, 'warnings')
        end
      else
        write_commit_marker(marker, head, leftover, warnings.strip.empty? ? 'ok' : 'warnings')
      end
    end
    def fail_commit_msg(warnings, plain, args, code)
      warnings = plain.lines.last(20).join if warnings.strip.empty?
      warnings.strip.empty? ? "git_commit_gpt #{args.join(' ')} failed (exit #{code})." : warnings
    end
  end
end
