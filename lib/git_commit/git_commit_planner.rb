# frozen_string_literal: true

require "open3"
require "shellwords"
require "colorize"

# Builds a commit plan from porcelain status, compacted diffs, and the LLM client.
class GitCommitPlanner
  def initialize(debug:, hint:, quiet: false, pathspecs: [])
    @debug = debug
    @hint = hint
    @quiet = quiet
    @pathspecs = Array(pathspecs)
    @capture = GitCommitDiffCapture.new(pathspecs: @pathspecs)
  end

  def build(show_diff:)
    status = status_for_plan
    return :no_changes if status.nil?

    context = plan_context(status)
    diff = uncommitted_diff(context[:budgets])
    @capture.show_if_needed(show_diff)
    finalize_plan(request_plan(status, context, diff), status)
  end

  private

  def run_cmd(cmd)
    output = Utility.utf8_safe(`#{cmd}`)
    return output if $?.success?

    warn "Command failed: #{cmd}".red
    exit 1
  end

  def porcelain_status
    run_cmd(["git", "status", "--porcelain", "--branch", *GitPathspec.args(@pathspecs)].shelljoin)
  end

  def status_for_plan
    status = porcelain_status
    return nil unless changes?(status)

    intend_untracked
    status = porcelain_status
    return nil unless changes?(status)

    status
  end

  def changes?(status_output)
    return true if status_output.lines.count { |line| !line.start_with?("##") }.positive?

    puts "No changes to commit.".yellow
    false
  end

  def intend_untracked
    paths = untracked_paths
    return if paths.empty?

    cmd = ["git", "add", "-N", *paths].map { |p| Shellwords.escape(p) }.join(" ")
    puts "Running: #{cmd}".green unless @quiet
    system("#{cmd} 2>/dev/null")
  end

  def untracked_paths
    out, _, status = Open3.capture3(
      "git", "ls-files", "--others", "--exclude-standard", *GitPathspec.args(@pathspecs)
    )
    return [] unless status.success?

    Utility.utf8_safe(out).split("\n").reject(&:empty?).reject { |p| GitCommitExecutor.ephemeral_path?(p) }
  end

  def plan_context(status)
    mr_numstat = @capture.fetch_mr_numstat
    recent_commits = Utility.utf8_safe(`git log -10 --oneline 2>/dev/null`).strip
    recent_commands = RecentShellCommands.last_few(5)
    {
      mr_numstat: mr_numstat,
      recent_commits: recent_commits,
      recent_commands: recent_commands,
      budgets: CommitPlanClient.diff_body_budgets_chars(
        cli_hint: @hint,
        status_output: status,
        recent_commits: recent_commits,
        recent_commands: recent_commands,
        mr_numstat: mr_numstat
      )
    }
  end

  def uncommitted_diff(budgets)
    diff = Utility.utf8_safe(@capture.compact_uncommitted_diff(budgets[:uncommitted]))
    diff = Utility.utf8_safe(@capture.fallback_uncommitted_diff) if diff.strip.empty?
    @capture.abort_without_uncommitted_diff if diff.nil?
    diff
  end

  def request_plan(status, context, diff)
    CommitPlanClient.new(debug: @debug, progress: !@quiet).commit_plan(
      status, context[:mr_numstat], diff, @hint, context[:recent_commits], context[:recent_commands]
    )
  end

  def finalize_plan(plan_result, status)
    result = CommitPlanFinalize.finalize_or_reject(
      plan_result[:plan], status, raw_response: plan_result[:raw_response]
    )
    return result if result.is_a?(Symbol)

    result_with_status(result, status)
  end

  def result_with_status(result, status)
    result["status_output"] = status
    result["status_snapshot"] = porcelain_status
    result
  end
end
