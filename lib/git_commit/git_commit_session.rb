# frozen_string_literal: true

require "colorize"

# One git_commit_gpt run: plan, confirm or auto-commit, then push or watch.
class GitCommitSession
  include GitCommitGit

  WATCH_INTERVAL = 30

  def initialize(options)
    @options = options
    @cwd = Dir.pwd
  end

  def run
    Dir.chdir(git_root)
    setup_planner
    puts "Model: #{model_name}".cyan unless @options.auto

    committed = apply_plan(@planner.build(show_diff: !@options.auto))
    return if @options.watch
    return unless committed

    finish_with_push
  end

  private

  def setup_planner
    @pathspecs = GitPathspec.resolve(@options.paths, cwd: @cwd, root: Dir.pwd)
    GitPathspec.assert_present!(@pathspecs)
    @pathspecs = GitStatusPaths.expand_partners(@pathspecs)
    @planner = GitCommitPlanner.new(
      debug: @options.debug, hint: @options.hint, quiet: @options.auto, pathspecs: @pathspecs
    )
  end

  def model_name
    OpenrouterClient.default_model
  end

  def apply_plan(plan)
    exit 1 if plan == :plan_rejected
    exit 0 if plan == :nothing_to_commit
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

  def start_watch(plan)
    announce_watch
    last_status = plan_status(plan) || plan["status_output"]
    loop do
      sleep WATCH_INTERVAL
      new_status = porcelain_status
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

end
