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
