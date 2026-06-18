# frozen_string_literal: true

# Post-processes LLM commit plans: path correction and reinclusion of wrongly excluded source files.
module CommitPlanFinalize
  module_function

  def finalize(plan, status_output)
    return nil unless plan.is_a?(Hash)

    commits = plan["commits"] || []
    return nil if commits.empty?

    status_filenames = porcelain_filenames(status_output)
    result = build_result(plan, commits, status_filenames)
    reinclude_excluded_code_files(result)
    result
  end

  def porcelain_filenames(porcelain_output)
    porcelain_output.split("\n").filter_map do |line|
      next if line.strip.empty? || line.start_with?("##")

      status_and_path = line.sub(/^.{2}\s+/, "")
      path = status_and_path.include?("->") ? status_and_path.split("->").last.strip : status_and_path
      path.match(/\A"(.*)"\z/) ? Regexp.last_match(1) : path
    end
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
  private_class_method :build_result, :reinclude_excluded_code_files, :partition_truncation_excluded,
    :code_file_excluded?, :append_paths_to_last_commit
end
