# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/loader"

class TestCommitPlanClient < Minitest::Test
  def test_missing_effort_falls_back_to_medium
    assert_equal "medium", CommitPlanClient.send(:reasoning_effort, {})
  end

  def test_blank_effort_falls_back_to_medium
    assert_equal "medium", CommitPlanClient.send(:reasoning_effort, "REASONING_EFFORT" => "   ")
  end

  def test_supported_effort_is_normalized_to_lowercase
    assert_equal "high", CommitPlanClient.send(:reasoning_effort, "REASONING_EFFORT" => "HIGH")
    assert_equal "medium", CommitPlanClient.send(:reasoning_effort, "REASONING_EFFORT" => " medium ")
  end

  def test_unsupported_effort_exits_before_any_request
    err = capture_io do
      assert_equal 1, assert_raises(SystemExit) {
        CommitPlanClient.send(:reasoning_effort, "REASONING_EFFORT" => "ultra")
      }.status
    end
    assert_match(/Invalid REASONING_EFFORT/, err[1])
    assert_match(/low, medium, high/, err[1])
  end
end
