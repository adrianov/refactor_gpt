# frozen_string_literal: true

# Normalizes raw LLM plan payloads: unwraps array wrappers and hoists nested
# plan keys out of quality_assessment.
module CommitPlanNormalization
  NESTED_PLAN_KEYS = %w[commits warnings excluded_files].freeze
  QA_FIELDS = %w[direction explanation].freeze

  module_function

  def normalize_plan(plan)
    plan = unwrap_plan_payload(plan)
    return plan unless plan.is_a?(Hash)

    qa = plan["quality_assessment"]
    return plan unless qa.is_a?(Hash) && nested_fields_in_qa?(qa)

    normalized = plan.dup
    NESTED_PLAN_KEYS.each { |key| normalized[key] = pick_plan_array(plan[key], qa[key]) }
    normalized["quality_assessment"] = qa.slice(*QA_FIELDS)
    normalized
  end

  # Some models wrap the plan object in a JSON array (ticket id + plan, or lone [plan]).
  def unwrap_plan_payload(plan)
    return plan if plan.is_a?(Hash)
    return plan unless plan.is_a?(Array)

    hashes = plan.filter_map { |item| unwrap_plan_payload(item) }.select { |item| item.is_a?(Hash) }
    hashes.find { |hash| plan_like?(hash) } || hashes.first || plan
  end

  def plan_like?(hash)
    hash.key?("commits") || hash.key?("quality_assessment")
  end

  def pick_plan_array(top, nested)
    top_arr = top.is_a?(Array) ? top : []
    nested_arr = nested.is_a?(Array) ? nested : []
    top_arr.any? ? top_arr : nested_arr
  end

  def nested_fields_in_qa?(qa)
    NESTED_PLAN_KEYS.any? { |key| qa.key?(key) }
  end
end
