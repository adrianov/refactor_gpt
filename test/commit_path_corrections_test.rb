# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/loader"

class TestCommitPathCorrections < Minitest::Test
  STATUS = %w[
    json/CMakeLists.txt
    json/jsonrpc-cpp/jsonrpc_httpserver.cpp
    json/jsonrpc-cpp/netstring.cpp
  ].freeze

  def test_corrects_glm_stripped_json_directory_prefix
    commits = [{ "files" => ["/CMakeLists.txt"] }]
    result = CommitPathCorrections.apply_to_commits(commits, STATUS)
    assert_equal ["json/CMakeLists.txt"], result.first["files"]
  end

  def test_corrects_glm_stripped_json_in_directory_and_basename
    commits = [{ "files" => ["/rpc-cpp/rpc_httpserver.cpp", "rpc-cpp/netstring.cpp"] }]
    result = CommitPathCorrections.apply_to_commits(commits, STATUS)
    assert_equal [
      "json/jsonrpc-cpp/jsonrpc_httpserver.cpp",
      "json/jsonrpc-cpp/netstring.cpp"
    ], result.first["files"]
  end

  def test_leaves_valid_paths_unchanged
    commits = [{ "files" => STATUS.dup }]
    result = CommitPathCorrections.apply_to_commits(commits, STATUS)
    assert_equal STATUS, result.first["files"]
  end

  def test_does_not_guess_when_stripped_path_is_ambiguous
    status = %w[json/a.rb jsonjsonjson/a.rb]
    commits = [{ "files" => ["a.rb"] }]
    result = CommitPathCorrections.apply_to_commits(commits, status)
    assert_equal ["a.rb"], result.first["files"]
  end
end
