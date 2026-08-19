# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/loader"

class TestGitPathspec < Minitest::Test
  def test_args_empty_without_paths
    assert_empty GitPathspec.args([])
    assert_empty GitPathspec.args(nil)
  end

  def test_args_prepends_double_dash
    assert_equal ["--", "a.rb", "b.rb"], GitPathspec.args(%w[a.rb b.rb])
  end

  def test_resolve_makes_repo_relative
    root = File.expand_path("..", __dir__)
    cwd = File.join(root, "lib")
    resolved = GitPathspec.resolve(["git_commit/git_pathspec.rb"], cwd: cwd, root: root)
    assert_equal ["lib/git_commit/git_pathspec.rb"], resolved
  end

  def test_resolve_keeps_globs
    root = File.expand_path("..", __dir__)
    assert_equal ["lib/*.rb"], GitPathspec.resolve(["lib/*.rb"], cwd: root, root: root)
  end
end
