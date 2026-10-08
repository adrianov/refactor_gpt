# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/loader"
require_relative "git_rebase_repo"

class TestGitCommitPush < Minitest::Test
  include GitRebaseRepo

  def test_git_push_publishes_rebased_branch_without_upstream
    Dir.mktmpdir do |dir|
      prepare_stale_clone(dir)
      Dir.chdir(File.join(dir, "clone")) { assert_published_new_branch(dir) }
    end
  end

  def test_plain_push_without_rebase
    assert_equal %w[git push], GitCommitRebase.push_command(nil)
  end

  def test_lease_push_when_upstream_exists
    in_repo("feature") do
      write_commit("a.rb", "a\n")
      add_upstream
      assert_equal %w[git push --force-with-lease], GitCommitRebase.push_command("origin/master")
    end
  end

  def test_tracks_new_branch_when_rebased_without_upstream
    in_repo("feature") do
      write_commit("a.rb", "a\n")
      system("git", "remote", "add", "origin", File.join(Dir.pwd, "bare.git"), exception: true)
      assert_equal ["git", "push", "-u", "origin", "HEAD"], GitCommitRebase.push_command("master")
    end
  end

  def test_git_push_rebases_and_leases
    Dir.mktmpdir do |dir|
      origin, clone = published_feature(dir)
      push_to_origin(origin, "b.rb", "b\n")
      Dir.chdir(clone) do
        error, output = capture_push

        assert_equal 0, error.status
        assert_match(/force-with-lease/, output)
        assert_equal sha("origin/master"), sha("HEAD^")
        assert_equal sha, remote_sha(origin, "feature")
      end
    end
  end

  def test_git_push_plain_when_base_is_current
    Dir.mktmpdir do |dir|
      Dir.chdir(published_feature(dir).last) do
        write_commit("d.rb", "d\n")
        error, output = capture_push

        assert_equal 0, error.status
        refute_match(/force-with-lease/, output)
        assert_equal sha, remote_sha(File.join(dir, "origin.git"), "feature")
      end
    end
  end

  def test_git_push_exits_when_push_fails
    in_repo("feature") do
      write_commit("a.rb", "a\n")
      error, = capture_push

      assert_equal 1, error.status
    end
  end
end
