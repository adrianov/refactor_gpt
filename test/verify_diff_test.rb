# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../hooks/quality'

class TestVerifyDiff < Minitest::Test
  class Probe
    include Quality::Support
    include Quality::VerifyDiff
  end

  def test_reverted_commit_shows_net_change_from_master
    in_repo('master') do |root|
      write_commit('lib/app.rb', "keep\n")
      system('git', 'checkout', '-q', '-b', 'feature', exception: true)
      write_commit('lib/app.rb', "keep\n#{'refactor\n' * 20}")
      File.write('lib/app.rb', "keep\ndust\n")

      body = Probe.new.verify_diff_body([File.join(root, 'lib/app.rb')])

      assert_match(/merge-base with master/, body)
      assert_match(/^\+dust$/, body)
      refute_match(/refactor/, body)
    end
  end

  def test_full_restore_reports_no_net_change
    in_repo('master') do |root|
      write_commit('lib/app.rb', "keep\n")
      system('git', 'checkout', '-q', '-b', 'feature', exception: true)
      write_commit('lib/app.rb', "keep\nrefactor\n")
      File.write('lib/app.rb', "keep\n")

      body = Probe.new.verify_diff_body([File.join(root, 'lib/app.rb')])

      assert_match(/No net changes since the branch point/, body)
      refute_match(/refactor/, body)
    end
  end

  def test_committed_file_is_included_when_only_another_file_is_dirty
    in_repo('master') do |root|
      write_commit('lib/kept.rb', "same\n")
      write_commit('lib/app.rb', "base\n")
      system('git', 'checkout', '-q', '-b', 'feature', exception: true)
      write_commit('lib/app.rb', "base\ncommitted\n")
      File.write('lib/dirty.rb', "dirty\n")

      body = Probe.new.verify_diff_body([File.join(root, 'lib/dirty.rb')])

      assert_match(%r{lib/app\.rb}, body)
      assert_match(/^\+committed$/, body)
      assert_match(%r{lib/dirty\.rb}, body)
      assert_match(/^\+dirty$/, body)
      refute_match(%r{lib/kept\.rb}, body)
    end
  end

  def test_includes_branch_commits_and_worktree
    in_repo('master') do |root|
      write_commit('lib/app.rb', "one\n")
      system('git', 'checkout', '-q', '-b', 'feature', exception: true)
      write_commit('lib/app.rb', "one\ntwo\n")
      File.write('lib/app.rb', "one\ntwo\nthree\n")

      body = Probe.new.verify_diff_body([File.join(root, 'lib/app.rb')])

      assert_match(/^\+two$/, body)
      assert_match(/^\+three$/, body)
    end
  end

  def test_origin_head_beats_a_local_master_that_moved
    in_repo('master') do |root|
      write_commit('lib/app.rb', "base\n")
      system('git', 'branch', 'main', exception: true)
      system('git', 'checkout', '-q', '-b', 'feature', exception: true)
      write_commit('lib/app.rb', "base\nfeature\n")
      system('git', 'update-ref', 'refs/remotes/origin/main', 'master', exception: true)
      system('git', 'update-ref', 'refs/remotes/origin/master', 'HEAD', exception: true)
      system('git', 'symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main', exception: true)
      File.write('lib/app.rb', "base\nfeature\nedit\n")

      body = Probe.new.verify_diff_body([File.join(root, 'lib/app.rb')])

      assert_match(/merge-base with origin\/main \(/, body)
      assert_match(/^\+feature$/, body)
      assert_match(/^\+edit$/, body)
    end
  end

  def test_uncommitted_against_head_when_no_default_branch
    in_repo('feature') do |root|
      write_commit('lib/app.rb', "one\n")
      File.write('lib/app.rb', "one\ntwo\n")
      File.write('lib/extra.rb', "extra\n")

      body = Probe.new.verify_diff_body([File.join(root, 'lib/app.rb'), File.join(root, 'lib/extra.rb')])

      assert_match(/uncommitted changes against HEAD/, body)
      refute_match(/merge-base/, body)
      assert_match(/^\+two$/, body)
      assert_match(/^\+extra$/, body)
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
        root = `git rev-parse --show-toplevel`.strip
        Dir.chdir(root) { yield root }
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
