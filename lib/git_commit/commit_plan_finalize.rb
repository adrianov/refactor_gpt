# frozen_string_literal: true

require "colorize"

# Post-processes LLM commit plans: schema normalization, path correction,
# and reinclusion of wrongly excluded source files.
module CommitPlanFinalize
  module_function

  def finalize_or_reject(plan, status_output, raw_response: nil)
    plan = CommitPlanNormalization.normalize_plan(plan)
    result = finalize(plan, status_output)
    return result if result
    return announce_nothing_to_commit(plan) if all_paths_excluded?(plan, status_output)

    warn_rejection(plan, status_output, raw_response: raw_response)
    :plan_rejected
  end

  def finalize(plan, status_output)
    plan = CommitPlanNormalization.normalize_plan(plan)
    return nil unless plan.is_a?(Hash)

    commits = plan["commits"] || []
    return nil if commits.empty?

    status_filenames = GitStatusPaths.filenames(status_output)
    result = build_result(plan, commits, status_filenames)
    reinclude_excluded_code_files(result)
    reinclude_missing_gone_paths(result, status_filenames)
    keep_status_paths(result, status_filenames)
    result["commits"].empty? ? nil : result
  end

  # A zero-commit plan is legitimate when every changed path was deliberately excluded.
  def all_paths_excluded?(plan, status_output)
    return false unless plan.is_a?(Hash)
    return false unless Array(plan["commits"]).empty?

    excluded = Array(plan["excluded_files"]).map { |entry| entry["path"].to_s }.to_set
    GitStatusPaths.filenames(status_output).all? { |path| excluded.include?(path) }
  end

  def announce_nothing_to_commit(plan)
    puts "Nothing to commit: every changed path is excluded.".yellow
    display_plan_extras(plan)
    hint_gitignore_for_finder_noise(Array(plan["excluded_files"]))
    :nothing_to_commit
  end

  def hint_gitignore_for_finder_noise(excluded)
    return unless excluded.any? { |entry| File.basename(entry["path"].to_s) == ".DS_Store" }

    puts "Hint: add .DS_Store to .gitignore to keep it out of git status.".cyan
  end

  def warn_rejection(plan, status_output, raw_response: nil)
    unless plan.is_a?(Hash)
      warn "Commit plan rejected: model response was not a JSON object.".red
      print_raw_response(raw_response)
      return
    end

    commits = plan["commits"] || []
    if commits.empty?
      warn_empty_commits(status_output, raw_response)
    else
      warn "Commit plan rejected: could not build a commit plan from the model response.".red
    end

    display_plan_extras(plan)
  end

  def warn_empty_commits(status_output, raw_response)
    paths = GitStatusPaths.filenames(status_output)
    warn "Commit plan rejected: model returned no commits.".red
    if paths.any?
      warn "Git status lists #{paths.size} changed path(s); re-run git_commit_gpt or pass --debug.".yellow
    end
    print_raw_response(raw_response)
  end

  def print_raw_response(raw_response)
    text = raw_response.to_s.strip
    return if text.empty?

    warn "Raw response:\n#{text}".red
  end

  def display_plan_extras(plan)
    return unless plan.is_a?(Hash)

    warnings = plan["warnings"] || []
    excluded = plan["excluded_files"] || []
    GitCommitDisplay.display_warnings(warnings) unless warnings.empty?
    GitCommitDisplay.display_excluded_files(excluded) unless excluded.empty?
  end

  def build_result(plan, commits, status_filenames)
    {
      "commits" => CommitPathCorrections.apply_to_commits(commits, status_filenames),
      "warnings" => plan["warnings"] || [],
      "quality_assessment" => plan["quality_assessment"],
      "excluded_files" => plan["excluded_files"] || []
    }
  end

  def reinclude_excluded_code_files(result)
    excluded = result["excluded_files"] || []
    commits = result["commits"] || []
    return if excluded.empty? || commits.empty?

    code_exts = DiffProcessor::CODE_EXTENSIONS
    kept, paths = partition_truncation_excluded(excluded, code_exts)
    return if paths.empty?

    result["excluded_files"] = kept
    append_paths_to_last_commit(commits, paths)
  end

  def keep_status_paths(result, status_filenames)
    allowed = status_filenames.to_set
    result["commits"] = Array(result["commits"]).filter_map do |commit|
      files = Array(commit["files"]).map(&:to_s).select { |path| allowed.include?(path) }.uniq
      next if files.empty?

      commit.merge("files" => files)
    end
  end

  def reinclude_missing_gone_paths(result, status_filenames)
    commits = result["commits"] || []
    return if commits.empty?

    listed = listed_plan_paths(result)
    missing = status_filenames.reject { |path| listed.include?(path) || File.exist?(path) }
    append_paths_to_last_commit(commits, missing)
  end

  def listed_plan_paths(result)
    files = Array(result["commits"]).flat_map { |c| Array(c["files"]) }
    excluded = Array(result["excluded_files"]).map { |e| e["path"] }
    (files + excluded).map(&:to_s).reject(&:empty?).to_set
  end

  def partition_truncation_excluded(excluded, code_exts)
    to_reinclude, kept = excluded.partition { |e| code_file_excluded?(e, code_exts) }
    paths = to_reinclude.map { |e| e["path"].to_s }.reject(&:empty?)
    [kept, paths]
  end

  def code_file_excluded?(entry, code_exts)
    path = entry["path"].to_s
    return false if path.empty?

    code_exts.include?(File.extname(path).downcase)
  end

  def append_paths_to_last_commit(commits, paths)
    return if paths.empty?

    last = commits.last
    last["files"] = Array(last["files"]) + paths
  end
  private_class_method :build_result, :reinclude_excluded_code_files, :keep_status_paths,
    :reinclude_missing_gone_paths,
    :listed_plan_paths, :partition_truncation_excluded,
    :code_file_excluded?, :append_paths_to_last_commit, :warn_rejection,
    :warn_empty_commits,
    :print_raw_response, :display_plan_extras, :all_paths_excluded?,
    :announce_nothing_to_commit, :hint_gitignore_for_finder_noise
end
