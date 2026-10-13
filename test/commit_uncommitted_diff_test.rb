# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/loader'

class TestCommitUncommittedDiff < Minitest::Test
  def test_uncommitted_diff_excludes_committed_edit
    in_repo('master') do
      write_commit('lib/app.rb', "base\n")
      system('git', 'checkout', '-q', '-b', 'feature', exception: true)
      write_commit('lib/app.rb', "base\ncommitted\n")
      File.write('lib/app.rb', "base\ncommitted\ndirty\n")

      dirty = GitCommitDiffCapture.new.compact_uncommitted_diff(50_000)

      assert_match(/^\+dirty$/, dirty)
      refute_match(/^\+committed$/, dirty)
    end
  end

  def test_branch_context_is_numstat_not_a_patch
    in_repo('master') do
      write_commit('lib/app.rb', "base\n")
      system('git', 'update-ref', 'refs/remotes/origin/HEAD', 'HEAD', exception: true)
      system('git', 'checkout', '-q', '-b', 'feature', exception: true)
      write_commit('lib/app.rb', "base\ncommitted\n")
      File.write('lib/app.rb', "base\ncommitted\ndirty\n")

      stat = GitCommitDiffCapture.new.fetch_mr_numstat

      assert_match(/\A\d+\t\d+\tlib\/app\.rb\z/, stat)
      refute_match(/^diff --git/, stat)
      refute_match(/^\+committed$/, stat)
    end
  end

  def test_no_branch_numstat_without_origin_head
    in_repo('master') do
      write_commit('lib/app.rb', "base\n")
      File.write('lib/app.rb', "base\ndirty\n")

      assert_equal '', GitCommitDiffCapture.new.fetch_mr_numstat
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
