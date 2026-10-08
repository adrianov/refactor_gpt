# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

# Temporary git repositories for rebase and push tests.
module GitRebaseRepo
  private

  def in_repo(branch)
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        system("git", "init", "-q", "-b", branch, exception: true)
        git_identity
        yield
      end
    end
  end

  def git_identity
    system("git", "config", "user.email", "t@t.com", exception: true)
    system("git", "config", "user.name", "t", exception: true)
    system("git", "config", "commit.gpgsign", "false", exception: true)
  end

  def write_commit(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    system("git", "add", path, exception: true)
    system("git", "commit", "-qm", "c", exception: true)
  end

  def checkout(branch)
    system("git", "checkout", "-q", branch, exception: true)
  end

  def sha(ref = "HEAD")
    out, status = Open3.capture2("git", "rev-parse", ref)
    raise "rev-parse #{ref}" unless status.success?

    out.strip
  end

  def run_rebase
    result = nil
    output, = capture_io { result = GitCommitRebase.run }
    [result, output]
  end

  def branch_with_moved_base
    write_commit("a.rb", "a\n")
    system("git", "checkout", "-q", "-b", "feature", exception: true)
    write_commit("c.rb", "c\n")
    checkout("master")
    write_commit("b.rb", "b\n")
    checkout("feature")
  end

  def conflict_with_moved_base
    write_commit("a.rb", "a\n")
    system("git", "checkout", "-q", "-b", "feature", exception: true)
    write_commit("a.rb", "feature\n")
    checkout("master")
    write_commit("a.rb", "master\n")
    checkout("feature")
  end

  def refute_rebase
    refute File.directory?(".git/rebase-merge")
    refute File.directory?(".git/rebase-apply")
  end

  def init_bare(path)
    system("git", "init", "--bare", "-q", "-b", "master", path, exception: true)
  end

  def push_to_origin(origin, path, content)
    Dir.mktmpdir do |seed|
      system("git", "clone", "-q", origin, seed, exception: true)
      Dir.chdir(seed) do
        git_identity
        write_commit(path, content)
        system("git", "push", "-q", "origin", "master", exception: true)
      end
    end
  end

  def clone_feature(origin, path)
    system("git", "clone", "-q", origin, path, exception: true)
    Dir.chdir(path) do
      git_identity
      system("git", "checkout", "-q", "-b", "feature", exception: true)
      write_commit("c.rb", "c\n")
    end
  end

  def add_upstream
    bare = File.join(Dir.pwd, "bare.git")
    system("git", "init", "--bare", "-q", "-b", "feature", bare, exception: true)
    system("git", "remote", "add", "origin", bare, exception: true)
    system("git", "push", "-q", "-u", "origin", "HEAD", exception: true)
  end

  def prepare_stale_clone(dir)
    origin = File.join(dir, "origin.git")
    init_bare(origin)
    push_to_origin(origin, "a.rb", "a\n")
    clone_feature(origin, File.join(dir, "clone"))
    push_to_origin(origin, "b.rb", "b\n")
  end

  def assert_fetched_rebase
    result, output = run_rebase

    assert_includes %w[origin/HEAD origin/master], result
    assert_equal sha("origin/master"), sha("HEAD^")
    assert_equal "c\n", File.read("c.rb")
    assert_match(/Running: git fetch origin/, output)
  end

  def assert_published_new_branch(dir)
    error, output = capture_push

    assert_equal 0, error.status
    assert_match(/git push -u origin HEAD/, output)
    assert_equal sha("origin/master"), sha("HEAD^")
    assert_equal sha, remote_sha(File.join(dir, "origin.git"), "feature")
  end

  def published_feature(dir)
    origin = File.join(dir, "origin.git")
    clone = File.join(dir, "clone")
    init_bare(origin)
    push_to_origin(origin, "a.rb", "a\n")
    clone_feature(origin, clone)
    Dir.chdir(clone) { system("git", "push", "-q", "-u", "origin", "HEAD", exception: true) }
    [origin, clone]
  end

  def capture_push
    error = nil
    output, = capture_io { error = assert_raises(SystemExit) { push_harness.go } }
    [error, output]
  end

  def remote_sha(origin, branch)
    out, status = Open3.capture2("git", "--git-dir", origin, "rev-parse", "refs/heads/#{branch}")
    raise branch unless status.success?

    out.strip
  end

  def push_harness
    Class.new do
      include GitCommitGit

      def go
        git_push
      end
    end.new
  end
end
