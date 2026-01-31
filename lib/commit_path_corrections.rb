# frozen_string_literal: true

# Corrects file paths from LLM commit-plan output (e.g. trailing dot → .json,
# missing "json" in basename). Add new correctors in correct_path.
module CommitPathCorrections
  module_function

  def apply_to_commits(commits, status_filenames)
    status_set = status_filenames.to_set
    deleted_paths = status_filenames.reject { |p| File.exist?(p) }

    commits.each do |commit|
      next unless commit["files"]

      commit["files"] = commit["files"].map do |path|
        correct_path(path, status_set, deleted_paths)
      end
    end

    commits
  end

  def correct_path(path, status_set, deleted_paths)
    return path if status_set.include?(path)
    restored = correct_missing_json_in_basename(path, status_set)
    return restored if restored
    return correct_trailing_dot_json(path, status_set) if path.end_with?(".")
    return resolve_deleted(path, deleted_paths) || path unless File.exist?(path)

    path
  end

  def correct_missing_json_in_basename(path, status_set)
    base = File.basename(path)
    return nil unless base.start_with?("_")

    candidate_base = "json_" + base.delete_prefix("_")
    dir = File.dirname(path)
    status_set.find { |s| File.dirname(s) == dir && File.basename(s) == candidate_base }
  end

  def correct_trailing_dot_json(path, status_set)
    without_dot = path.sub(/\.$/, "")
    status_set.include?("#{without_dot}.json") ? "#{without_dot}.json" : path
  end

  def resolve_deleted(plan_path, deleted_paths)
    stem = File.basename(plan_path, ".*")
    deleted_paths.find { |p| File.basename(p).start_with?(stem) }
  end
end
