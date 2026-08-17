# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/loader"

class TestCommitPlanResponse < Minitest::Test
  def test_parse_accepts_trailing_comma_before_closing_brace
    raw = <<~JSON
      {
        "quality_assessment": {
          "direction": "increased",
          "explanation": "UTC stamps match CURRENT_TIMESTAMP.",
        },
        "commits": [
          {
            "message": "feat: store created_at as UTC wall-clock",
            "files": ["lib/database.rb"]
          }
        ],
        "warnings": [],
        "excluded_files": []
      }
    JSON
    plan = CommitPlanResponse.parse(raw, 1)
    assert_equal "increased", plan.dig("quality_assessment", "direction")
    assert_equal ["lib/database.rb"], plan.dig("commits", 0, "files")
  end
end
