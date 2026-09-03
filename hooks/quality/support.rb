# frozen_string_literal: true

require 'open3'

module Quality
  # Shell/git helpers, path-kind predicates, stage/flags, and active locks.
  module Support
    # Vendored/generated dirs mirror abcop's own third-party prune.
    VENDORED_DIR_RE = %r{
      (^|/)(vendor|node_modules|bower_components|Pods|Carthage|target|dist|
      build|out|third_party|third-party|3rdparty|external|coverage|DerivedData)/
    }ix

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
      cache = (@git_tops ||= {})
      key = dir.to_s
      return cache[key] if cache.key?(key)

      out, _, code = capture('git', '-C', key, 'rev-parse', '--show-toplevel')
      cache[key] = code.zero? ? out.strip : nil
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
      VENDORED_DIR_RE =~ path || path =~ %r{(^|/)db/migrate/}i
    end
    def main_module?(path)
      path =~ MAIN_EXT && path !~ %r{(^|/)(docs|doc)/}i && !routing_file?(path) &&
        !third_party?(path) && !spec_or_test?(path)
    end
    def md_only?(files)
      list = Array(files).reject { |f| f.to_s.empty? }
      !list.empty? && list.all? { |f| f =~ /\.md$/i }
    end
    def truncate(text)
      s = text.to_s
      s.bytesize <= LIMIT ? s : "#{s.byteslice(0, LIMIT)}\n... (truncated)"
    end
  end
end
