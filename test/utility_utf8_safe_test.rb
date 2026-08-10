# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/loader"

class UtilityUtf8SafeTest < Minitest::Test
  def test_utf8_safe_allows_strip_under_us_ascii_locale
    with_us_ascii_locale do
      raw = ascii_tagged("ceacbda Fix Timepad — Москва\n")
      assert_equal Encoding::US_ASCII, raw.encoding
      assert_raises(Encoding::CompatibilityError) { raw.strip }

      safe = Utility.utf8_safe(raw)
      assert_equal Encoding::UTF_8, safe.encoding
      assert_equal "ceacbda Fix Timepad — Москва", safe.strip
    end
  end

  def test_utf8_join_normalizes_parts_before_concat
    with_us_ascii_locale do
      label = "Here is git log:\n\n"
      commits = ascii_tagged("a75b598 Recall — Москва\n")
      naive = label + commits
      assert_equal Encoding::US_ASCII, naive.encoding
      assert_raises(Encoding::CompatibilityError) { naive.strip }

      joined = Utility.utf8_join("\n", label, commits)
      assert_equal Encoding::UTF_8, joined.encoding
      assert_equal "Here is git log:\n\n\na75b598 Recall — Москва", joined.strip
    end
  end

  def test_commit_plan_builds_utf8_payload_from_ascii_tagged_git_bits
    with_us_ascii_locale do
      status = ascii_tagged("## main\n M file.rb\n")
      commits = ascii_tagged("a75b598 Recall — Москва\n")
      diff = ascii_tagged("+puts 'hello'\n")
      numstat = ascii_tagged("1\t2\tpath.rb\n")
      budgets = CommitPlanClient.diff_body_budgets_chars(
        cli_hint: "",
        status_output: status,
        recent_commits: Utility.utf8_safe(commits).strip,
        recent_commands: "",
        mr_numstat: numstat
      )
      assert budgets[:uncommitted].positive?

      content = CommitPlanClient.allocate.send(
        :build_user_content, status, numstat, diff, "",
        Utility.utf8_safe(commits).strip, ""
      )
      assert_equal Encoding::UTF_8, content.encoding
      assert content.valid_encoding?
      assert_includes content, "Москва"
      assert_includes content, "path.rb"
    end
  end

  private

  def ascii_tagged(str)
    str.dup.force_encoding(Encoding::US_ASCII)
  end

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
