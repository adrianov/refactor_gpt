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
    # One action line per pipeline event, appended to LOGS/quality.log and
    # mirrored on STDERR so the driving agent's transcript captures it too.
    # Logging must never raise: swallow every failure.
    def log_action(event, **fields)
      line = build_log_line(event, fields)
      file = File.join(LOGS, 'quality.log')
      FileUtils.mkdir_p(LOGS)
      rotate_oversized_log(file)
      File.open(file, 'a') { |f| f.puts line }
      STDERR.puts line
    rescue StandardError
      nil
    end

    def build_log_line(event, fields)
      parts = fields.reject { |_, v| v.nil? || v.to_s.empty? }.map { |k, v| "#{k}=#{v}" }
      "[quality] #{Time.now.strftime('%F %T%z')} pid=#{$$} session=#{@session_key} " \
        "#{event} #{parts.join(' ')}".rstrip
    end

    def rotate_oversized_log(file)
      File.truncate(file, 0) if File.exist?(file) && File.size(file) > 5_000_000
    end
    # Times a block and logs its duration under the given stage name.
    def timed(stage)
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      log_action('done', stage: stage, ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round)
      result
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
    # True when the first workspace root's repo remote belongs to OWN_GITHUB.
    def owned_workspace?
      root = workspace_git_root
      return false unless root

      owned_remote?(git_remote(root))
    end
    def owned_remote?(remote)
      !OWN_GITHUB.empty? && !remote.to_s.empty? && !!(remote =~ %r{github\.com[:/]#{Regexp.escape(OWN_GITHUB)}/}i)
    end
    def workspace_git_root
      w = @roots[0].to_s
      w.empty? || !File.directory?(w) ? nil : git_root(w)
    end
    def spec_or_test?(path)
      path =~ SPEC_RE || path =~ SPEC_FILE_RE || path =~ SPEC_SUFFIX_RE || path =~ TEST_PREFIX_RE
    end
    def routing_file?(path)
      File.basename(path) =~ /^routes\.rb$/i || path =~ %r{(^|/)config/routes/}i
    end

    # Vendored/generated material is never owned production code, whatever
    # the diff touched: size findings there have no action you can take
    # upstream. Mirrors abcop's scoped-run third-party prune.
    def third_party?(path)
      path =~ %r{(^|/)(vendor|node_modules|bower_components|Pods|Carthage|target|dist|build|out|third_party|third-party|3rdparty|external|coverage|DerivedData)/}i ||
        path =~ %r{(^|/)db/migrate/}i
    end
    def prod_module?(path)
      return false unless path =~ PROD_EXT
      return false if path =~ %r{(^|/)[^/]*lock\.ya?ml$}i || path =~ %r{(^|/)(docs|doc|translations|icons?|images?)/}i
      return false if (path =~ %r{(^|/)assets/}i && path !~ /\.(css|scss|sass)$/i) ||
                     path =~ %r{(^|/)db/schema\.rb$}i || routing_file?(path)
      return false if third_party?(path)

      !spec_or_test?(path)
    end
    def main_module?(path)
      path =~ MAIN_EXT && path !~ %r{(^|/)(docs|doc)/}i && !routing_file?(path) &&
        !third_party?(path) && !spec_or_test?(path)
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
  end
end
