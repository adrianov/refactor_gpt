# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/loader"

class TestGitCommitOptions < Minitest::Test
  def test_commit_defaults_to_auto
    options = GitCommitOptions.parse([])
    assert_equal "auto", options.commit
    refute options.auto
    refute options.push
  end

  def test_commit_flag_accepts_yes_no_auto
    assert_equal "yes", GitCommitOptions.parse(%w[--commit yes]).commit
    assert_equal "no", GitCommitOptions.parse(%w[--commit no]).commit
    assert_equal "auto", GitCommitOptions.parse(%w[--commit auto]).commit
    assert_equal "yes", GitCommitOptions.parse(["--commit=yes"]).commit
  end

  def test_commit_flag_is_optional_and_leaves_hint
    options = GitCommitOptions.parse(["fix login"])
    assert_equal "auto", options.commit
    assert_equal "fix login", options.hint
  end

  def test_invalid_commit_aborts
    capture_io do
      assert_raises(SystemExit) { GitCommitOptions.parse(%w[--commit maybe]) }
      assert_raises(SystemExit) { GitCommitOptions.parse(%w[--commit]) }
    end
  end

  def test_interactive_auto_proceeds_only_without_warnings
    options = GitCommitOptions.parse([])
    assert options.proceed_without_prompt?([], quiet: false)
    refute options.proceed_without_prompt?([{"description" => "risk"}], quiet: false)
  end

  def test_commit_yes_always_proceeds
    options = GitCommitOptions.parse(%w[--commit yes])
    assert options.proceed_without_prompt?([{"probability" => 0.9}], quiet: false)
    assert options.proceed_without_prompt?([{"probability" => 0.9}], quiet: true)
  end

  def test_commit_no_never_proceeds
    options = GitCommitOptions.parse(%w[--commit no])
    refute options.proceed_without_prompt?([], quiet: false)
    refute options.proceed_without_prompt?([], quiet: true)
  end

  def test_quiet_auto_uses_warning_level
    options = GitCommitOptions.parse(%w[--auto])
    assert_equal "auto", options.commit
    assert options.proceed_without_prompt?([{"probability" => 0.4}], quiet: true)
    refute options.proceed_without_prompt?([{"probability" => 0.8}], quiet: true)
  end
end
