# frozen_string_literal: true

# Corrects, filters, and restores paths in a normalized commit plan.
module CommitPlanPaths
  private

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

    kept, paths = partition_truncation_excluded(excluded, DiffProcessor::CODE_EXTENSIONS)
    return if paths.empty?

    result["excluded_files"] = kept
    append_paths_to_last_commit(commits, paths)
  end

  def keep_status_paths(result, status_filenames)
    allowed = status_filenames.to_set
    result["commits"] = Array(result["commits"]).filter_map do |commit|
      files = Array(commit["files"]).map(&:to_s).select { |path| allowed.include?(path) }.uniq
      commit.merge("files" => files) unless files.empty?
    end
  end

  def reinclude_missing_gone_paths(result, status_filenames)
    commits = result["commits"] || []
    return if commits.empty?

    listed = listed_plan_paths(result)
    append_paths_to_last_commit(
      commits, status_filenames.reject { |path| listed.include?(path) || File.exist?(path) }
    )
  end

  def listed_plan_paths(result)
    (
      Array(result["commits"]).flat_map { |commit| Array(commit["files"]) } +
      Array(result["excluded_files"]).map { |entry| entry["path"] }
    )
      .map(&:to_s).reject(&:empty?).to_set
  end

  def partition_truncation_excluded(excluded, code_exts)
    to_reinclude, kept = excluded.partition { |entry| code_file_excluded?(entry, code_exts) }
    [kept, to_reinclude.map { |entry| entry["path"].to_s }.reject(&:empty?)]
  end

  def code_file_excluded?(entry, code_exts)
    path = entry["path"].to_s
    !path.empty? && code_exts.include?(File.extname(path).downcase)
  end

  def append_paths_to_last_commit(commits, paths)
    return if paths.empty?

    commits.last["files"] = Array(commits.last["files"]) + paths
  end
end
