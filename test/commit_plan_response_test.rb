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

  def test_strip_preserves_comma_inside_string_before_brace
    raw = <<~JSON
      {
        "quality_assessment": {
          "direction": "same",
          "explanation": "Note about format, } keeps going."
        },
        "commits": [],
        "warnings": ["looks like, ] here"],
        "excluded_files": []
      }
    JSON
    plan = CommitPlanResponse.parse(raw, 1)
    assert_equal "Note about format, } keeps going.", plan.dig("quality_assessment", "explanation")
    assert_equal ["looks like, ] here"], plan["warnings"]
  end

  def test_strip_trailing_and_preserve_string_commas_together
    raw = <<~JSON
      {
        "quality_assessment": {
          "direction": "decreased",
          "explanation": "Broken text, } still in string",
        },
        "commits": [],
        "warnings": [],
        "excluded_files": [],
      }
    JSON
    plan = CommitPlanResponse.parse(raw, 1)
    assert_equal "Broken text, } still in string", plan.dig("quality_assessment", "explanation")
  end
end
