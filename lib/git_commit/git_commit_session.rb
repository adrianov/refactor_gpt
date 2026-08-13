# frozen_string_literal: true

require "colorize"

# One git_commit_gpt run: plan, confirm or auto-commit, then push or watch.
class GitCommitSession
  WATCH_INTERVAL = 30

  def initialize(options)
    @options = options
    @planner = GitCommitPlanner.new(debug: options.debug, hint: options.hint, quiet: options.auto)
  end

  def run
    Dir.chdir(git_root)
    puts "Model: #{model_name}".cyan unless @options.auto

    plan = @planner.build(show_diff: !@options.auto)
    committed = apply_plan(plan)
    return if @options.watch
    return unless committed

    finish_with_push
  end

  private

  def git_root
    root = Utility.utf8_safe(`git rev-parse --show-toplevel 2>/dev/null`).strip
    return root if $?.success?

    puts "Not in a git repository".red
    exit 1
  end

  def model_name
    OpenAiClient.new(debug: @options.debug, progress_title: nil).model
  end

  def run_cmd(cmd)
    output = Utility.utf8_safe(`#{cmd}`)
    return output if $?.success?

    warn "Command failed: #{cmd}".red
    exit 1
  end

  def apply_plan(plan)
    exit 1 if plan == :plan_rejected
    return unless plan.is_a?(Hash)

    if @options.watch
      present_plan(plan)
      return start_watch(plan)
    end

    prepare_commits(plan)
    assert_status_unchanged(plan["status_snapshot"])
    GitCommitExecutor.execute_commits(plan["commits"])
  end

  def prepare_commits(plan)
    warnings = Array(plan["warnings"])
    return prepare_quiet_commits(warnings) if @options.auto

    present_plan(plan)
    prepare_interactive_commits(warnings)
  end

  def prepare_quiet_commits(warnings)
    GitCommitDisplay.display_warnings(warnings)
    return if @options.proceed_without_prompt?(warnings, quiet: true)

    skip_commit
  end

  def prepare_interactive_commits(warnings)
    return if @options.proceed_without_prompt?(warnings, quiet: false)

    @options.commit == "no" ? skip_commit : GitCommitDisplay.get_user_confirmation
  end

  def skip_commit
    if @options.auto && @options.commit != "no"
      puts "Auto-commit skipped: a warning is above #{@options.warning_level}%.".yellow
      exit 1
    end

    puts "Commands not executed.".yellow
    exit 0
  end

  def present_plan(plan)
    CompletionNotifier.notify_completion(success: true, title: "✓ Commit plan ready")
    if @options.auto
      GitCommitDisplay.display_warnings(Array(plan["warnings"]))
      GitCommitDisplay.display_planned_commits(Array(plan["commits"]))
      return
    end

    GitCommitDisplay.display_commits_result(
      plan["commits"], plan["warnings"], plan["quality_assessment"], plan["excluded_files"]
    )
  end

  def assert_status_unchanged(snapshot)
    return if snapshot.nil? || snapshot.empty?
    return if run_cmd("git status --porcelain --branch") == snapshot

    warn "Abort: working tree changed after planning.".red
    warn "Re-run git_commit_gpt, or commit/stash the other changes first.".red
    exit 1
  end

  def start_watch(plan)
    announce_watch
    last_status = plan_status(plan) || plan["status_output"]
    loop do
      sleep WATCH_INTERVAL
      new_status = run_cmd("git status --porcelain --branch")
      next if new_status == last_status

      refreshed = @planner.build(show_diff: false)
      last_status = plan_status(refreshed) || new_status
      next unless refreshed.is_a?(Hash)

      present_plan(refreshed)
      announce_watch
    end
  end

  def plan_status(plan)
    plan.is_a?(Hash) ? plan["status_snapshot"] || plan["status_output"] : nil
  end

  def announce_watch
    puts "Watching for changes every #{WATCH_INTERVAL}s. Ctrl+C to exit.".yellow
  end

  def finish_with_push
    remote = Utility.utf8_safe(`git remote 2>/dev/null`).strip
    if remote.empty?
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
    puts "Running: git push".green
    system("git push") || exit(1)
    exit 0
  end
end
