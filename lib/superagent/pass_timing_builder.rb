# frozen_string_literal: true

# Builds pass-timing hash for display. Extracted to keep Superagent under length limit.
module PassTimingBuilder
  PHASE_KEYS = %i[refactor_time implementation_time review_time fix_time].freeze

  module_function

  def build(pass, model, implementation_time: 0, review_time: 0, fix_time: 0, refactor_time: 0, total_time: 0)
    {
      pass: pass,
      model: model,
      implementation_time: implementation_time,
      review_time: review_time,
      fix_time: fix_time,
      refactor_time: refactor_time,
      total_time: total_time
    }
  end

  def phase_times_sum(pass_timing)
    PHASE_KEYS.sum { |k| pass_timing[k] || 0 }
  end
end
