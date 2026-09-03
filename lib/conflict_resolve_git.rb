# frozen_string_literal: true

require 'colorize'
require 'shellwords'

# Supplies git state and commit context for conflict resolution.
module ConflictResolveGit
  private

  def git_root
    root = `git rev-parse --show-toplevel 2>/dev/null`.strip
    abort 'Not in a git repository.'.red unless $?.success? && !root.empty?

    root
  end

  def merge_in_progress?(root)
    metadata = git_dir(root)
    File.exist?(File.join(metadata, 'MERGE_HEAD')) ||
      File.exist?(File.join(metadata, 'rebase-merge')) ||
      File.exist?(File.join(metadata, 'rebase-apply'))
  end

  def git_dir(root)
    dir = `git rev-parse --git-dir 2>/dev/null`.strip
    abort 'Could not determine git metadata directory.'.red unless $?.success? && !dir.empty?

    File.expand_path(dir, root)
  end

  def conflicted_files
    `git diff --name-only --diff-filter=U`.split("\n").map(&:strip).reject(&:empty?)
  end

  def reference_files(files)
    (files + `git diff --name-only --cached`.split("\n") + `git diff --name-only`.split("\n"))
      .map(&:strip).reject(&:empty?).uniq.select { |path| File.file?(path) }
  end

  def read_files(paths)
    paths.each_with_object({}) { |path, contents| contents[path] = File.read(path) }
  end

  def conflict_commit_context
    [head_sha, *merge_head_shas].compact.uniq.filter_map { |sha| format_commit_context(sha) }.join("\n\n")
  end

  def head_sha
    sha = `git rev-parse HEAD 2>/dev/null`.strip
    return sha if $?.success? && !sha.empty?
  end

  def merge_head_shas
    heads = `git rev-parse --verify MERGE_HEAD 2>/dev/null`.split("\n").map(&:strip).reject(&:empty?)
    return heads if $?.success?

    []
  end

  def format_commit_context(sha)
    details = `git show -s --format=%B #{Shellwords.escape(sha)} 2>/dev/null`.strip
    return nil unless $?.success?

    description = details.empty? ? '(no commit message body)' : details
    <<~TEXT.strip
      <conflict_commit sha="#{sha}">
      #{description}
      </conflict_commit>
    TEXT
  end
end
