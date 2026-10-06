# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/loader'

class TestCommitBranchDiff < Minitest::Test
  def test_branch_diff_includes_committed_and_uncommitted
    in_repo('master') do
      write_commit('lib/app.rb', "base\n")
      system('git', 'checkout', '-q', '-b', 'feature', exception: true)
      write_commit('lib/app.rb', "base\ncommitted\n")
      File.write('lib/app.rb', "base\ncommitted\ndirty\n")

      capture = GitCommitDiffCapture.new
      branch = capture.compact_branch_diff(capture.branch_rev, 50_000)
      dirty = capture.compact_uncommitted_diff(50_000)

      assert_match(/^\+committed$/, branch)
      assert_match(/^\+dirty$/, branch)
      assert_match(/^\+dirty$/, dirty)
      refute_match(/^\+committed$/, dirty)
    end
  end

  def test_no_branch_diff_when_not_diverged
    in_repo('master') do
      write_commit('lib/app.rb', "base\n")
      File.write('lib/app.rb', "base\ndirty\n")

      capture = GitCommitDiffCapture.new

      assert_nil capture.branch_rev
      assert_equal '', capture.compact_branch_diff(nil, 50_000)
    end
  end

  def test_origin_head_is_the_branch_point
    in_repo('master') do
      write_commit('lib/app.rb', "base\n")
      system('git', 'checkout', '-q', '-b', 'feature', exception: true)
      write_commit('lib/app.rb', "base\nfeature\n")
      system('git', 'update-ref', 'refs/remotes/origin/main', 'master', exception: true)
      system('git', 'update-ref', 'refs/remotes/origin/master', 'HEAD', exception: true)
      system('git', 'symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main', exception: true)
      File.write('lib/app.rb', "base\nfeature\nedit\n")

      body = GitCommitDiffCapture.new.compact_branch_diff(GitCommitDiffCapture.new.branch_rev, 50_000)

      assert_match(/^\+feature$/, body)
      assert_match(/^\+edit$/, body)
    end
  end

  private

  def in_repo(branch)
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        system('git', 'init', '-q', '-b', branch, exception: true)
        system('git', 'config', 'user.email', 't@t.com', exception: true)
        system('git', 'config', 'user.name', 't', exception: true)
        system('git', 'config', 'commit.gpgsign', 'false', exception: true)
        yield
      end
    end
  end

  def write_commit(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    system('git', 'add', path, exception: true)
    system('git', 'commit', '-qm', 'c', exception: true)
  end
end
