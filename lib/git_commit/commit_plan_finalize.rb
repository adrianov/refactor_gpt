# frozen_string_literal: true

# Post-processes LLM commit plans through path correction and validation helpers.
module CommitPlanFinalize
  extend CommitPlanNotices
  extend CommitPlanPaths

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
end
