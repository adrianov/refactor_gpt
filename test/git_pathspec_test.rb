# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
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

  def test_deleted_tracked_file_is_known
    in_repo do
      File.write("gone.rb", "ok\n")
      system("git", "add", "gone.rb", exception: true)
      system("git", "commit", "-qm", "init", exception: true)
      File.delete("gone.rb")

      assert GitPathspec.known_to_git?("gone.rb")
      refute GitPathspec.known_to_git?("missing.rb")
      GitPathspec.assert_present!(["gone.rb"])
    end
  end

  private

  def in_repo
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        system("git", "init", "-q", exception: true)
        system("git", "config", "user.email", "t@t.com", exception: true)
        system("git", "config", "user.name", "t", exception: true)
        system("git", "config", "commit.gpgsign", "false", exception: true)
        yield
      end
    end
  end
end
