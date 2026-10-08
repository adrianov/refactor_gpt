# frozen_string_literal: true

require "colorize"
require "shellwords"

# Repository commands, status checks, and push; a clean rebase onto a moved base uses --force-with-lease.
module GitCommitGit
  private

  def git_root
    root = Utility.utf8_safe(`git rev-parse --show-toplevel 2>/dev/null`).strip
    return root if $?.success?

    puts "Not in a git repository".red
    exit 1
  end

  def run_cmd(cmd)
    output = Utility.utf8_safe(`#{cmd}`)
    return output if $?.success?

    warn "Command failed: #{cmd}".red
    exit 1
  end

  def porcelain_status
    run_cmd(["git", "status", "--porcelain", "--branch", *GitPathspec.args(@pathspecs)].shelljoin)
  end

  def assert_status_unchanged(snapshot)
    return if snapshot.nil? || snapshot.empty? || porcelain_status == snapshot

    warn "Abort: working tree changed after planning.".red
    warn "Re-run git_commit_gpt, or commit/stash the other changes first.".red
    exit 1
  end

  def finish_with_push
    if Utility.utf8_safe(`git remote 2>/dev/null`).strip.empty?
      puts "Committed. No remote configured.".yellow
      exit 0
    end

    return git_push if @options.push
    return skip_push if @options.auto || !push_confirmed?

    git_push
  end

  def push_confirmed?
    puts "Push these commits? (y/N)".white
    PromptReader.read_line("", downcase: true) == "y"
  end

  def skip_push
    puts "Committed locally; push skipped.".yellow
    exit 0
  end

  def git_push
    command = GitCommitRebase.push_command(GitCommitRebase.run)
    puts "Running: #{command.join(" ")}".green
    system(*command) || exit(1)
    exit 0
  end
end
