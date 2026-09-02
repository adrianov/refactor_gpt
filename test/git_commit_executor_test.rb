# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/loader"

class TestGitCommitExecutor < Minitest::Test
  def test_commit_omits_unknown_pathspecs
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        init_repo
        File.write("real.rb", "ok\n")
        system("git", "add", "real.rb", exception: true)
        system("git", "commit", "-qm", "init", exception: true)
        File.write("real.rb", "changed\n")

        ok = nil
        capture_io do
          ok = GitCommitExecutor.execute_single_commit(
            "message" => "fix: real",
            "files" => %w[real.rb phantom.rb]
          )
        end

        assert ok
        assert_equal %w[real.rb], committed_paths
      end
    end
  end

  def test_commits_deleted_tracked_file
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        init_repo
        File.write("gone.rb", "ok\n")
        system("git", "add", "gone.rb", exception: true)
        system("git", "commit", "-qm", "init", exception: true)
        File.delete("gone.rb")

        ok = nil
        capture_io do
          ok = GitCommitExecutor.execute_single_commit(
            "message" => "chore: remove gone",
            "files" => %w[gone.rb]
          )
        end

        assert ok
        assert_equal %w[gone.rb], committed_paths
        refute File.exist?("gone.rb")
      end
    end
  end

  def test_commits_rename_including_source_deletion
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        init_repo
        File.write("old.rb", "same\n")
        system("git", "add", "old.rb", exception: true)
        system("git", "commit", "-qm", "init", exception: true)
        system("git", "mv", "old.rb", "new.rb", exception: true)

        ok = nil
        capture_io do
          ok = GitCommitExecutor.execute_single_commit(
            "message" => "refactor: rename old to new",
            "files" => %w[old.rb new.rb]
          )
        end

        assert ok
        assert_empty `git status --porcelain`
        assert_match(/R100\told\.rb\tnew\.rb/, `git log -1 --name-status`)
      end
    end
  end

  def test_commits_rename_when_plan_lists_only_destination
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        init_repo
        File.write("old.rb", "same\n")
        system("git", "add", "old.rb", exception: true)
        system("git", "commit", "-qm", "init", exception: true)
        system("git", "mv", "old.rb", "new.rb", exception: true)

        ok = nil
        capture_io do
          ok = GitCommitExecutor.execute_single_commit(
            "message" => "refactor: rename old to new",
            "files" => %w[new.rb]
          )
        end

        assert ok
        assert_empty `git status --porcelain`
        assert_match(/R100\told\.rb\tnew\.rb/, `git log -1 --name-status`)
      end
    end
  end

  def test_commits_worktree_delete_and_add_as_rename
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        init_repo
        File.write("old.rb", "same\n")
        system("git", "add", "old.rb", exception: true)
        system("git", "commit", "-qm", "init", exception: true)
        File.delete("old.rb")
        File.write("new.rb", "same\n")

        ok = nil
        capture_io do
          ok = GitCommitExecutor.execute_single_commit(
            "message" => "refactor: rename old to new",
            "files" => %w[old.rb new.rb]
          )
        end

        assert ok
        assert_empty `git status --porcelain`
        log = `git log -1 --name-status`
        assert(log.include?("old.rb") && log.include?("new.rb"))
      end
    end
  end

  def test_skips_commit_when_no_planned_path_is_staged
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        init_repo
        File.write("tracked.rb", "ok\n")
        system("git", "add", "tracked.rb", exception: true)
        system("git", "commit", "-qm", "init", exception: true)

        ok = true
        capture_io do
          ok = GitCommitExecutor.execute_single_commit(
            "message" => "feat: phantom",
            "files" => %w[phantom.rb]
          )
        end

        refute ok
        assert_equal "init", `git log -1 --format=%s`.strip
      end
    end
  end

  private

  def init_repo
    system("git", "init", "-q", exception: true)
    system("git", "config", "user.email", "t@t.com", exception: true)
    system("git", "config", "user.name", "t", exception: true)
    system("git", "config", "commit.gpgsign", "false", exception: true)
  end

  def committed_paths
    `git diff-tree --no-commit-id --name-only -r HEAD`.split("\n").reject(&:empty?)
  end
end
