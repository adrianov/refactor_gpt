# frozen_string_literal: true

require "open3"
require "colorize"

# Git pathspec argv (`-- path...`) and cwd-to-repo-root path resolution for git_commit_gpt.
module GitPathspec
  module_function

  def args(paths)
    list = Array(paths).map(&:to_s).reject(&:empty?)
    list.empty? ? [] : ["--", *list]
  end

  def resolve(paths, cwd:, root:)
    repo = File.expand_path(root)
    Array(paths).filter_map { |path| resolve_one(path, cwd, repo) }
  end

  def assert_present!(paths)
    Array(paths).each { |path| assert_one!(path) }
  end

  def resolve_one(path, cwd, root)
    raw = path.to_s
    return if raw.empty?
    return raw if glob?(raw)

    abs = File.expand_path(raw, cwd)
    rel = Pathname.new(abs).relative_path_from(Pathname.new(root)).to_s
    abort_outside(raw) if rel.start_with?("..")
    rel
  rescue ArgumentError
    abort_outside(raw)
  end

  def glob?(path)
    path.match?(/[*?\[]/)
  end

  def assert_one!(path)
    return if glob?(path)
    return if File.exist?(path)
    return if known_to_git?(path)

    warn "Path not found: #{path}".red
    exit 1
  end

  def known_to_git?(path)
    return true if system("git", "ls-files", "--error-unmatch", "--", path, out: File::NULL, err: File::NULL)

    out, _, status = Open3.capture3("git", "status", "--porcelain", "--", path)
    status.success? && out.lines.any? { |line| !line.start_with?("##") }
  end

  def abort_outside(path)
    warn "Path is outside the repository: #{path}".red
    exit 1
  end
end
