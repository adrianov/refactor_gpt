# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/loader"

class TestCommitPlanFinalize < Minitest::Test
  def test_porcelain_filenames_extracts_modified_and_renamed_paths
    status = <<~STATUS
      ## main...origin/main
       M app/models/user.rb
      R100 old.rb -> new.rb
    STATUS
    assert_equal %w[app/models/user.rb new.rb], CommitPlanFinalize.porcelain_filenames(status)
  end

  def test_finalize_reincludes_wrongly_excluded_source_file
    status = " M app/services/user/sync_attributes.rb\n"
    plan = {
      "commits" => [{ "message" => "refactor: simplify adult check", "files" => [] }],
      "warnings" => [],
      "excluded_files" => [{ "path" => "app/services/user/sync_attributes.rb",
                             "reason" => "diff omitted under limits" }]
    }
    result = CommitPlanFinalize.finalize(plan, status)
    files = result["commits"].flat_map { |c| c["files"] }
    assert_includes files, "app/services/user/sync_attributes.rb"
    assert_empty result["excluded_files"]
  end

  def test_finalize_returns_nil_when_llm_returns_empty_commits
    status = " M only.rb\n"
    plan = { "commits" => [], "warnings" => [], "excluded_files" => [] }
    assert_nil CommitPlanFinalize.finalize(plan, status)
  end

  def test_finalize_or_reject_warns_when_commits_empty
    status = " M only.rb\n"
    plan = { "commits" => [], "warnings" => [{ "description" => "test warning" }], "excluded_files" => [] }
    raw = '{"commits":[],"warnings":[{"description":"test warning"}]}'
    err = capture_io do
      assert_equal :plan_rejected, CommitPlanFinalize.finalize_or_reject(plan, status, raw_response: raw)
    end
    assert_match(/no commits/i, err[1])
    assert_match(/Raw response:/, err[1])
    assert_match(/test warning/, err[1])
  end
end
