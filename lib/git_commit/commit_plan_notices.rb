# frozen_string_literal: true

require "colorize"

# Explains rejected or fully excluded commit plans to the user.
module CommitPlanNotices
  private

  def all_paths_excluded?(plan, status_output)
    return false unless plan.is_a?(Hash)
    return false unless Array(plan["commits"]).empty?

    excluded = Array(plan["excluded_files"]).map { |entry| entry["path"].to_s }.to_set
    GitStatusPaths.filenames(status_output).all? { |path| excluded.include?(path) }
  end

  def announce_nothing_to_commit(plan)
    puts "Nothing to commit: every changed path is excluded.".yellow
    display_plan_extras(plan)
    if Array(plan["excluded_files"]).any? { |entry| File.basename(entry["path"].to_s) == ".DS_Store" }
      puts "Hint: add .DS_Store to .gitignore to keep it out of git status.".cyan
    end
    :nothing_to_commit
  end

  def warn_rejection(plan, status_output, raw_response: nil)
    unless plan.is_a?(Hash)
      warn "Commit plan rejected: model response was not a JSON object.".red
      print_raw_response(raw_response)
      return
    end

    if Array(plan["commits"]).empty?
      warn_empty_commits(status_output, raw_response)
    else
      warn "Commit plan rejected: could not build a commit plan from the model response.".red
    end
    display_plan_extras(plan)
  end

  def warn_empty_commits(status_output, raw_response)
    paths = GitStatusPaths.filenames(status_output)
    warn "Commit plan rejected: model returned no commits.".red
    warn "Git status lists #{paths.size} changed path(s); re-run git_commit_gpt or pass --debug.".yellow if paths.any?
    print_raw_response(raw_response)
  end

  def print_raw_response(raw_response)
    text = raw_response.to_s.strip
    warn "Raw response:\n#{text}".red unless text.empty?
  end

  def display_plan_extras(plan)
    return unless plan.is_a?(Hash)

    warnings = plan["warnings"] || []
    excluded = plan["excluded_files"] || []
    GitCommitDisplay.display_warnings(warnings) unless warnings.empty?
    GitCommitDisplay.display_excluded_files(excluded) unless excluded.empty?
  end
end
