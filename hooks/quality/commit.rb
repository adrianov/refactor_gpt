# frozen_string_literal: true

module Quality
  # git_commit_gpt invocation and its result bookkeeping: readiness gates for a
  # repo, whole-repo run under a temp lock, and commit/warning markers that let
  # later pipeline turns short-circuit unchanged dirt.
  module CommitStage
    def run_commit
      root = workspace_git_root
      return nil unless commit_ready?(root)

      ctx = commit_context(root)
      return nil if ctx[:prior][0] == ctx[:head] && ctx[:prior][1] == ctx[:dirt]

      run_commit_locked(root, ctx)
    end

    def commit_context(root)
      key = Digest::SHA256.hexdigest(root)
      FileUtils.mkdir_p(STATE)
      marker = File.join(STATE, "git-commit-#{@session_key}-#{key}")
      prior = File.file?(marker) ? File.readlines(marker).map(&:chomp) : []
      { own: owned_remote?(git_remote(root)), key: key, marker: marker, head: git_head(root),
        prior: prior, dirt: git_dirt_hash(root) }
    end

    def commit_ready?(root)
      return false unless root && !git_remote(root).empty?
      return false if capture('git', '-C', root, 'status', '--porcelain')[0].to_s.empty?

      File.executable?(RBENV_RUBY) && File.file?(COMMIT_GPT)
    end

    def run_commit_locked(root, ctx)
      FileUtils.mkdir_p(LOGS)
      lock = File.join(@tmpdir, "git-commit-gpt-#{ctx[:key]}.lock")
      return nil unless acquire_lock(lock)

      begin
        args = ctx[:own] ? %w[--auto --push] : ['--auto', '--commit', 'no']
        STDERR.puts "[quality] git_commit_gpt #{args.join(' ')} (whole repo)"
        out, err, code = capture(RBENV_RUBY, COMMIT_GPT, *args, chdir: root)
        combined = "#{out}#{err}"
        File.open(File.join(LOGS, "git-commit-gpt-#{ctx[:key]}.log"), 'a') { |f| f.puts combined }
        finish_commit(root, ctx, combined, code, args)
      ensure
        Dir.rmdir(lock) if File.directory?(lock)
      end
    end

    def finish_commit(root, ctx, combined, code, args)
      leftover = (h = git_dirt_hash(root)).empty? ? ctx[:dirt] : h
      plain = combined.gsub(/\e\[[0-9;]*[a-zA-Z]/, '')
      warnings = plain.lines.select { |l| l =~ /^Warning in |^Auto-commit skipped:/ }.join
      return success_commit_result(root, ctx, leftover, warnings) if code == 0

      write_commit_marker(ctx[:marker], ctx[:head], leftover, 'warnings')
      fail_commit_msg(warnings, plain, args, code)
    end

    def success_commit_result(root, ctx, leftover, warnings)
      record_commit_marker(ctx, leftover, warnings, git_head(root))
      warnings.strip.empty? ? nil : warnings
    end

    def git_dirt_hash(root)
      blob = capture('git', '-C', root, 'status', '--porcelain')[0].to_s +
             capture('git', '-C', root, 'diff', 'HEAD')[0].to_s
      capture('git', '-C', root, 'ls-files', '--others', '--exclude-standard', '-z')[0].to_s.split("\0").each do |f|
        next if f.empty?

        blob += "UNTRACKED #{f} #{capture('git', '-C', root, 'hash-object', '--', f)[0]}"
      end
      Digest::SHA256.hexdigest(blob)
    end
  end
end
