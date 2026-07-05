# frozen_string_literal: true

require "colorize"

# Post-processes LLM commit plans: path correction and reinclusion of wrongly excluded source files.
module CommitPlanFinalize
  module_function

  def finalize_or_reject(plan, status_output, raw_response: nil)
    result = finalize(plan, status_output)
    return result if result

    warn_rejection(plan, status_output, raw_response: raw_response)
    :plan_rejected
  end

  def finalize(plan, status_output)
    return nil unless plan.is_a?(Hash)

    commits = plan["commits"] || []
    return nil if commits.empty?

    status_filenames = porcelain_filenames(status_output)
    result = build_result(plan, commits, status_filenames)
    reinclude_excluded_code_files(result)
    result
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
    paths = porcelain_filenames(status_output)
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
    :code_file_excluded?, :append_paths_to_last_commit, :warn_rejection, :warn_empty_commits,
    :print_raw_response, :display_plan_extras
end
