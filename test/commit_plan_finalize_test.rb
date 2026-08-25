# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/loader"

class TestCommitPlanFinalize < Minitest::Test
  def test_finalize_reincludes_omitted_rename_source
    status = "R100 old.rb -> new.rb\n"
    plan = {
      "commits" => [{ "message" => "refactor: rename old.rb", "files" => ["new.rb"] }],
      "warnings" => [],
      "excluded_files" => []
    }
    result = CommitPlanFinalize.finalize(plan, status)
    files = result["commits"].flat_map { |c| c["files"] }
    assert_includes files, "old.rb"
    assert_includes files, "new.rb"
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

  def test_finalize_hoists_commits_nested_in_quality_assessment
    status = " M json/CMakeLists.txt\n M json/jsonrpc-cpp/jsonrpc_httpserver.cpp\n M json/jsonrpc-cpp/netstring.cpp\n"
    plan = {
      "quality_assessment" => {
        "direction" => "increased",
        "explanation" => "Safer snprintf usage.",
        "commits" => [
          { "message" => "Replace sprintf with snprintf in rpc-cpp modules",
            "files" => ["/rpc-cpp/rpc_httpserver.cpp", "/rpc-cpp/netstring.cpp"] },
          { "message" => "Raise cmake minimum version to 3.10 for rpcpp",
            "files" => ["/CMakeLists.txt"] }
        ],
        "warnings" => [],
        "excluded_files" => []
      }
    }
    result = CommitPlanFinalize.finalize(plan, status)
    files = result["commits"].flat_map { |c| c["files"] }
    expected = %w[
      json/CMakeLists.txt
      json/jsonrpc-cpp/jsonrpc_httpserver.cpp
      json/jsonrpc-cpp/netstring.cpp
    ]
    assert_equal expected.sort, files.sort
    assert_equal "increased", result["quality_assessment"]["direction"]
    assert_nil result["quality_assessment"]["commits"]
  end

  def test_finalize_unwraps_array_wrapped_plan
    status = " M app/models/exchanger.rb\n M app/interactors/ex_matching/match.rb\n"
    plan = [
      ["PT-8741"],
      {
        "quality_assessment" => {
          "direction" => "increased",
          "explanation" => "Dust leftover detection uses fix_price."
        },
        "commits" => [
          { "message" => "[PT-8741] fix: evaluate limit dust by fix_price",
            "files" => ["app/models/exchanger.rb"] },
          { "message" => "[PT-8741] fix: finish counter-party dust makers",
            "files" => ["app/interactors/ex_matching/match.rb"] }
        ],
        "warnings" => [],
        "excluded_files" => []
      }
    ]
    result = CommitPlanFinalize.finalize(plan, status)
    assert_equal 2, result["commits"].size
    assert_equal "increased", result["quality_assessment"]["direction"]
    files = result["commits"].flat_map { |c| c["files"] }
    assert_equal %w[app/interactors/ex_matching/match.rb app/models/exchanger.rb].sort, files.sort
  end

  def test_finalize_drops_paths_not_in_git_status
    status = " M README.md\n"
    plan = {
      "commits" => [{
        "message" => "feat: send order buttons",
        "files" => [
          "README.md",
          "app/services/usedesk/send_order_buttons.rb",
          "spec/services/usedesk/send_order_buttons_spec.rb"
        ]
      }],
      "warnings" => [],
      "excluded_files" => []
    }
    result = CommitPlanFinalize.finalize(plan, status)
    assert_equal ["README.md"], result["commits"].first["files"]
  end

  def test_finalize_returns_nil_when_all_paths_are_unknown
    status = " M README.md\n"
    plan = {
      "commits" => [{
        "message" => "feat: send order buttons",
        "files" => ["spec/services/usedesk/send_order_buttons_spec.rb"]
      }],
      "warnings" => [],
      "excluded_files" => []
    }
    assert_nil CommitPlanFinalize.finalize(plan, status)
  end

  def test_finalize_or_reject_accepts_fully_excluded_plan_as_nothing_to_commit
    status = "?? .DS_Store\n"
    plan = {
      "commits" => [],
      "warnings" => [],
      "excluded_files" => [{ "path" => ".DS_Store", "reason" => "macOS Finder metadata file" }]
    }
    out, err = capture_io do
      assert_equal :nothing_to_commit, CommitPlanFinalize.finalize_or_reject(plan, status)
    end
    assert_match(/Nothing to commit/, out)
    assert_match(/macOS Finder metadata/, out)
    assert_match(/gitignore/, out)
    refute_match(/Raw response:/, err)
  end

  def test_finalize_or_reject_rejects_partially_covered_status_paths
    status = " M app/models/user.rb\n?? .DS_Store\n"
    plan = {
      "commits" => [],
      "warnings" => [],
      "excluded_files" => [{ "path" => ".DS_Store", "reason" => "macOS Finder metadata file" }]
    }
    _out, err = capture_io do
      assert_equal :plan_rejected, CommitPlanFinalize.finalize_or_reject(plan, status)
    end
    assert_match(/no commits/i, err)
  end
end
