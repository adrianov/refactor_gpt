# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/loader"

class TestGitCommitOptions < Minitest::Test
  def test_commit_defaults_to_auto
    options = GitCommitOptions.parse([])
    assert_equal "auto", options.commit
    refute options.auto
    refute options.push
  end

  def test_commit_flag_accepts_yes_no_auto
    assert_equal "yes", GitCommitOptions.parse(%w[--commit yes]).commit
    assert_equal "no", GitCommitOptions.parse(%w[--commit no]).commit
    assert_equal "auto", GitCommitOptions.parse(%w[--commit auto]).commit
    assert_equal "yes", GitCommitOptions.parse(["--commit=yes"]).commit
  end

  def test_commit_flag_is_optional_and_leaves_hint
    options = GitCommitOptions.parse(["fix login"])
    assert_equal "auto", options.commit
    assert_equal "fix login", options.hint
  end

  def test_invalid_commit_aborts
    capture_io do
      assert_raises(SystemExit) { GitCommitOptions.parse(%w[--commit maybe]) }
      assert_raises(SystemExit) { GitCommitOptions.parse(%w[--commit]) }
    end
  end

  def test_interactive_auto_proceeds_only_without_warnings
    options = GitCommitOptions.parse([])
    assert options.proceed_without_prompt?([], quiet: false)
    refute options.proceed_without_prompt?([{"description" => "risk"}], quiet: false)
  end

  def test_commit_yes_always_proceeds
    options = GitCommitOptions.parse(%w[--commit yes])
    assert options.proceed_without_prompt?([{"probability" => 0.9}], quiet: false)
    assert options.proceed_without_prompt?([{"probability" => 0.9}], quiet: true)
  end

  def test_commit_no_never_proceeds
    options = GitCommitOptions.parse(%w[--commit no])
    refute options.proceed_without_prompt?([], quiet: false)
    refute options.proceed_without_prompt?([], quiet: true)
  end

  def test_quiet_auto_uses_warning_level
    options = GitCommitOptions.parse(%w[--auto])
    assert_equal "auto", options.commit
    assert options.proceed_without_prompt?([{"probability" => 0.4}], quiet: true)
    refute options.proceed_without_prompt?([{"probability" => 0.8}], quiet: true)
  end

  def test_paths_default_empty
    assert_empty GitCommitOptions.parse([]).paths
  end

  def test_file_flag_collects_paths_and_leaves_hint
    options = GitCommitOptions.parse(%w[--file lib/foo.rb --file=lib/bar.rb keep messages short])
    assert_equal %w[lib/foo.rb lib/bar.rb], options.paths
    assert_equal "keep messages short", options.hint
  end

  def test_double_dash_collects_remaining_as_paths
    options = GitCommitOptions.parse(%w[--auto -- deleted.rb other.rb])
    assert_equal %w[deleted.rb other.rb], options.paths
    assert options.auto
    assert_equal "", options.hint
  end

  def test_slash_path_is_not_hint
    options = GitCommitOptions.parse(%w[lib/missing.rb a hint])
    assert_equal %w[lib/missing.rb], options.paths
    assert_equal "a hint", options.hint
  end

  def test_deleted_tracked_file_is_path_not_hint
    in_repo do
      File.write("gone.rb", "ok\n")
      system("git", "add", "gone.rb", exception: true)
      system("git", "commit", "-qm", "init", exception: true)
      File.delete("gone.rb")

      options = GitCommitOptions.parse(%w[gone.rb a hint])
      assert_equal %w[gone.rb], options.paths
      assert_equal "a hint", options.hint
    end
  end

  def test_staged_deletion_is_path_not_hint
    in_repo do
      File.write("gone.rb", "ok\n")
      system("git", "add", "gone.rb", exception: true)
      system("git", "commit", "-qm", "init", exception: true)
      system("git", "rm", "-q", "gone.rb", exception: true)

      options = GitCommitOptions.parse(%w[gone.rb keep it])
      assert_equal %w[gone.rb], options.paths
      assert_equal "keep it", options.hint
    end
  end

  def test_unknown_basename_is_hint
    options = GitCommitOptions.parse(%w[no_such_file.rb please])
    assert_empty options.paths
    assert_equal "no_such_file.rb please", options.hint
  end

  def test_invalid_file_flag_aborts
    capture_io do
      assert_raises(SystemExit) { GitCommitOptions.parse(%w[--file]) }
      assert_raises(SystemExit) { GitCommitOptions.parse(%w[--file --auto]) }
      assert_raises(SystemExit) { GitCommitOptions.parse(["--file="]) }
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
