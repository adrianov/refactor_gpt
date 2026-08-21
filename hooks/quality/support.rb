# frozen_string_literal: true

require 'open3'
require 'fileutils'
require 'digest'

module Quality
  # Shell/git helpers, path-kind predicates, stage/flags, and active locks.
  module Support
    def capture(*cmd, chdir: nil, stdin_data: nil)
      o = {}
      o[:chdir] = chdir if chdir
      o[:stdin_data] = stdin_data if stdin_data
      out, err, st = o.empty? ? Open3.capture3(*cmd) : Open3.capture3(*cmd, o)
      [out, err, st.exitstatus]
    rescue StandardError => e
      ['', e.message, 1]
    end
    def which(name)
      ENV['PATH'].to_s.split(':').map { |d| File.join(d, name) }.find { |p| File.file?(p) && File.executable?(p) }
    end
    def git_root(dir)
      out, _, code = capture('git', '-C', dir.to_s, 'rev-parse', '--show-toplevel')
      code == 0 ? out.to_s.strip : nil
    rescue StandardError
      nil
    end
    def git_head(root)
      out, _, code = capture('git', '-C', root, 'rev-parse', 'HEAD')
      code == 0 ? out.to_s.strip : ''
    end
    def git_remote(root)
      out, _, code = capture('git', '-C', root, 'remote', 'get-url', 'origin')
      return out.to_s.strip if code == 0 && !out.to_s.strip.empty?

      out, _, code = capture('git', '-C', root, 'remote', '-v')
      code == 0 ? out.to_s.lines[0].to_s.split[1].to_s : ''
    end
    def rel_to(root, abs)
      prefix = root.end_with?('/') ? root : "#{root}/"
      abs.start_with?(prefix) ? abs[prefix.length..-1] : nil
    end
    def owned_repo?(path)
      (r = git_root(File.dirname(path))) && owned_remote?(git_remote(r))
    end
    def owned_remote?(remote)
      !OWN_GITHUB.empty? && !remote.to_s.empty? && !!(remote =~ %r{github\.com[:/]#{Regexp.escape(OWN_GITHUB)}/}i)
    end
    def workspace_git_root
      w = @roots[0].to_s
      w.empty? || !File.directory?(w) ? nil : git_root(w)
    end
    def ruby_project_root(file)
      dir = File.dirname(file)
      dir = File.dirname(dir) while dir != '/' && !File.file?(File.join(dir, 'Gemfile'))
      dir == '/' ? (ENV['CURSOR_PROJECT_DIR'] || File.dirname(file)) : dir
    end
    def group_by_ruby_root(files)
      files.each_with_object({}) do |abs, g|
        next unless File.file?(abs)

        root = ruby_project_root(abs)
        (g[root] ||= []) << (rel_to(root, abs) || abs)
      end
    end
    def spec_or_test?(path)
      path =~ SPEC_RE || path =~ SPEC_FILE_RE || path =~ SPEC_SUFFIX_RE || path =~ TEST_PREFIX_RE
    end
    def routing_file?(path)
      File.basename(path) =~ /^routes\.rb$/i || path =~ %r{(^|/)config/routes/}i
    end
    def prod_module?(path)
      return false unless path =~ PROD_EXT
      return false if path =~ %r{(^|/)[^/]*lock\.ya?ml$}i || path =~ %r{(^|/)(docs|doc|translations|icons?|images?)/}i
      return false if (path =~ %r{(^|/)assets/}i && path !~ /\.(css|scss|sass)$/i) ||
                     path =~ %r{(^|/)db/schema\.rb$}i || routing_file?(path)

      !spec_or_test?(path)
    end
    def main_module?(path)
      path =~ MAIN_EXT && path !~ %r{(^|/)(docs|doc)/}i && !routing_file?(path) && !spec_or_test?(path)
    end
    def md_only?(files)
      list = Array(files).reject { |f| f.to_s.empty? }
      !list.empty? && list.all? { |f| f =~ /\.md$/i }
    end
    def line_count(path)
      n = 0
      File.foreach(path) { n += 1 }
      n
    rescue StandardError
      0
    end
    def truncate(text)
      s = text.to_s
      s.bytesize <= LIMIT ? s : "#{s.byteslice(0, LIMIT)}\n... (truncated)"
    end
    def session_files_record; @session_key.empty? ? nil : File.join(STATE, "session-files-#{@session_key}"); end
    def pending_file; File.join(STATE, "stop-pending-#{@session_key}"); end
    def review_flag_file(name); File.join(STATE, "stop-#{name}-#{@session_key}"); end
    def review_flag?(name); File.file?(review_flag_file(name)); end
    def stage_file; File.join(STATE, "stop-stage-#{@session_key}"); end
    def active_lock_path(k); File.join(STATE, "quality-active-#{k}-#{@session_key}"); end
    def write_commit_marker(path, head, dirt, status); File.write(path, "#{head}\n#{dirt}\n#{status}\n"); end
    def finish_empty; release_active; empty; end
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
    def cleanup_state
      FileUtils.mkdir_p(STATE)
      cutoff = Time.now - 7 * 86_400
      Dir.glob(File.join(STATE, '*')).each { |f| (File.delete(f) if File.file?(f) && File.mtime(f) < cutoff) rescue nil }
    rescue StandardError
      nil
    end
    def claim_active(root)
      return if root.nil? || root.empty? || @session_key.empty?

      FileUtils.mkdir_p(STATE)
      @active_root_key = Digest::SHA256.hexdigest(root)
      File.write(active_lock_path(@active_root_key), "#{Process.pid}\n#{Time.now.to_i}\n")
    end
    def release_active
      path = active_lock_path(@active_root_key) if @active_root_key && !@session_key.empty?
      File.delete(path) if path && File.file?(path)
    rescue StandardError
      nil
    ensure
      @active_root_key = nil
    end
    def last_active_runner?
      key = @active_root_key
      release_active
      return true if key.nil? || @session_key.empty?

      sweep_active_locks(key)
      Dir.glob(File.join(STATE, "quality-active-#{key}-*")).empty?
    end
    def sweep_active_locks(root_key)
      now = Time.now.to_i
      Dir.glob(File.join(STATE, "quality-active-#{root_key}-*")).each do |path|
        (File.delete(path) if File.file?(path) && now - File.mtime(path).to_i >= ACTIVE_LOCK_AGE) rescue nil
      end
    rescue StandardError
      nil
    end
    def acquire_lock(dir)
      true if Dir.mkdir(dir)
    rescue Errno::EEXIST
      mtime = File.mtime(dir).to_i rescue 0
      return false if Time.now.to_i - mtime < LOCK_AGE

      Dir.rmdir(dir) rescue nil
      Dir.mkdir(dir)
      true
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
