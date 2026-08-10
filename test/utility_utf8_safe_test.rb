# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/loader"

class UtilityUtf8SafeTest < Minitest::Test
  def test_utf8_safe_allows_strip_under_us_ascii_locale
    with_us_ascii_locale do
      raw = "ceacbda Fix Timepad — Москва\n".dup.force_encoding(Encoding::US_ASCII)
      assert_equal Encoding::US_ASCII, raw.encoding
      assert_raises(Encoding::CompatibilityError) { raw.strip }

      safe = Utility.utf8_safe(raw)
      assert_equal Encoding::UTF_8, safe.encoding
      assert_equal "ceacbda Fix Timepad — Москва", safe.strip
    end
  end

  def test_utf8_join_normalizes_parts_before_concat
    with_us_ascii_locale do
      label = "Here is git log:\n\n" # UTF-8 source
      commits = "a75b598 Recall — Москва\n".dup.force_encoding(Encoding::US_ASCII)
      naive = label + commits
      assert_equal Encoding::US_ASCII, naive.encoding
      assert_raises(Encoding::CompatibilityError) { naive.strip }

      joined = Utility.utf8_join("\n", label, commits)
      assert_equal Encoding::UTF_8, joined.encoding
      assert_equal "Here is git log:\n\n\na75b598 Recall — Москва", joined.strip
    end
  end

  def test_commit_plan_data_utf8_before_budget_format
    with_us_ascii_locale do
      commits = "a75b598 Recall — Москва\n".dup.force_encoding(Encoding::US_ASCII)
      budgets = CommitPlanClient.diff_body_budgets_chars(
        cli_hint: "",
        status_output: "## main\n M file.rb\n".dup.force_encoding(Encoding::US_ASCII),
        recent_commits: commits,
        recent_commands: "",
        mr_numstat: ""
      )
      assert_kind_of Integer, budgets[:uncommitted]
      assert budgets[:uncommitted].positive?
    end
  end

  private

  def with_us_ascii_locale
    old_external = Encoding.default_external
    old_internal = Encoding.default_internal
    Encoding.default_external = Encoding::US_ASCII
    Encoding.default_internal = nil
    yield
  ensure
    Encoding.default_external = old_external
    Encoding.default_internal = old_internal
  end
end
