# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/loader"
require_relative "git_rebase_repo"

class TestGitCommitRebase < Minitest::Test
  include GitRebaseRepo

  def test_rebases_when_base_moved_without_conflict
    in_repo("master") do
      branch_with_moved_base
      result, output = run_rebase

      assert_equal "master", result
      assert_equal sha("master"), sha("HEAD^")
      assert_equal "c\n", File.read("c.rb")
      assert_match(/Running: git rebase master/, output)
      refute_match(/not cleanly/, output)
      refute_rebase
    end
  end

  def test_skips_when_branch_point_is_base_head
    in_repo("master") do
      write_commit("a.rb", "a\n")
      system("git", "checkout", "-q", "-b", "feature", exception: true)
      write_commit("c.rb", "c\n")
      head = sha
      result, output = run_rebase

      assert_nil result
      assert_equal head, sha
      refute_match(/rebase/, output)
    end
  end

  def test_skips_rebase_when_replay_conflicts
    in_repo("master") do
      conflict_with_moved_base
      head = sha
      result, output = run_rebase

      assert_nil result
      assert_equal head, sha
      assert_equal "feature\n", File.read("a.rb")
      assert_match(/pushing without rebase/, output)
      refute_rebase
    end
  end

  def test_skips_dirty_worktree
    in_repo("master") do
      branch_with_moved_base
      File.write("c.rb", "dirty\n")
      head = sha
      result, output = run_rebase

      assert_nil result
      assert_equal head, sha
      assert_match(/pushing without rebase/, output)
      refute_rebase
    end
  end

  def test_does_not_rebase_default_branch
    in_repo("master") do
      write_commit("a.rb", "a\n")
      system("git", "checkout", "-q", "-b", "side", exception: true)
      write_commit("b.rb", "b\n")
      system("git", "update-ref", "refs/remotes/origin/master", "HEAD", exception: true)
      checkout("master")
      head = sha
      result, = run_rebase

      assert_nil result
      assert_equal head, sha
    end
  end

  def test_warns_when_fetch_fails
    Dir.mktmpdir do |dir|
      prepare_unreachable_stale_clone(dir)
      Dir.chdir(File.join(dir, "clone")) { assert_stale_fetch_rebase }
    end
  end

  def test_fetches_remote_base_then_rebases
    Dir.mktmpdir do |dir|
      prepare_stale_clone(dir)
      Dir.chdir(File.join(dir, "clone")) { assert_fetched_rebase }
    end
  end

  private

  def prepare_unreachable_stale_clone(dir)
    prepare_stale_clone(dir)
    clone = File.join(dir, "clone")
    Dir.chdir(clone) { system("git", "fetch", "-q", "origin", exception: true) }
    push_to_origin(File.join(dir, "origin.git"), "d.rb", "d\n")
    system("git", "-C", clone, "remote", "set-url", "origin", File.join(dir, "missing.git"), exception: true)
  end

  def assert_stale_fetch_rebase
    stale = sha("origin/master")
    result, output = run_rebase

    assert_match(/stale remote-tracking refs/, output)
    assert_equal stale, sha("origin/master")
    assert_equal stale, sha(result)
    assert_equal stale, sha("HEAD^")
    assert_equal "b\n", File.read("b.rb")
    refute File.exist?("d.rb")
  end
end
