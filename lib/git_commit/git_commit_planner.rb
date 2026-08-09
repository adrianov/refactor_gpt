# frozen_string_literal: true

require "shellwords"
require "colorize"

# Builds a commit plan from porcelain status, compacted diffs, and the LLM client.
class GitCommitPlanner
  def initialize(debug:, hint:, quiet: false)
    @debug = debug
    @hint = hint
    @quiet = quiet
  end

  def build(show_diff:)
    status = status_for_plan
    return :no_changes if status.nil?

    context = plan_context(status)
    diff = uncommitted_diff(context[:budgets])
    GitCommitDiffCapture.show_if_needed(show_diff)
    show_rubocop_hint(status) if show_diff
    finalize_plan(request_plan(status, context, diff), status)
  end

  private

  def run_cmd(cmd)
    output = `#{cmd}`
    return output if $?.success?

    warn "Command failed: #{cmd}".red
    exit 1
  end

  def status_for_plan
    status = run_cmd("git status --porcelain --branch")
    return nil unless changes?(status)

    intend_untracked
    status = run_cmd("git status --porcelain --branch")
    return nil unless changes?(status)

    status
  end

  def changes?(status_output)
    return true if status_output.lines.count { |line| !line.start_with?("##") }.positive?

    puts "No changes to commit.".yellow
    false
  end

  def intend_untracked
    paths = `git ls-files --others --exclude-standard`.split("\n").reject(&:empty?)
    paths.reject! { |p| GitCommitExecutor.ephemeral_path?(p) }
    return if paths.empty?

    cmd = ["git", "add", "-N", *paths].map { |p| Shellwords.escape(p) }.join(" ")
    puts "Running: #{cmd}".green unless @quiet
    system("#{cmd} 2>/dev/null")
  end

  def plan_context(status)
    mr_numstat = GitCommitDiffCapture.fetch_mr_numstat
    recent_commits = `git log -10 --oneline 2>/dev/null`.strip
    recent_commands = RecentShellCommands.last_few(5)
    budgets = CommitPlanClient.diff_body_budgets_chars(
      cli_hint: @hint,
      status_output: status,
      recent_commits: recent_commits,
      recent_commands: recent_commands,
      mr_numstat: mr_numstat
    )
    { mr_numstat: mr_numstat, recent_commits: recent_commits, recent_commands: recent_commands, budgets: budgets }
  end

  def uncommitted_diff(budgets)
    diff = GitCommitDiffCapture.compact_uncommitted_diff(budgets[:uncommitted])
    diff = GitCommitDiffCapture.fallback_uncommitted_diff if diff.strip.empty?
    GitCommitDiffCapture.abort_without_uncommitted_diff if diff.nil?
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
    return :plan_rejected if result == :plan_rejected

    result["status_output"] = status
    result["status_snapshot"] = run_cmd("git status --porcelain --branch")
    result
  end

  def show_rubocop_hint(status)
    cmd = GitCommitRubocop.suggestion(status)
    return unless cmd

    puts "Run RuboCop before committing:".yellow
    puts cmd.cyan
    puts
  end
end
