# frozen_string_literal: true

require "open3"
require "shellwords"
require "colorize"

# Stages planned paths and runs git commit for each entry in a commit plan.
# Staged path matching uses name-status so rename/copy sources are not dropped.
module GitCommitExecutor
  # Basename globs for build artifacts and scratch files: never `git add -N` for analyze nor `git add` on commit.
  EPHEMERAL_BASENAME_GLOBS = [
    '*.log', '*.tmp', '*.temp', '*.bak', '*.swp', '*.swo',
    '*.pyc', '*.pyo', '*.class', '*.jar', '*.war', '*.ear',
    '*.zip', '*.tar.gz', '*.tgz', '*.rar', '*.exe', '*.dll',
    '*.so', '*.dylib', '*.bin', '*.dat', '*.orig', '*.rej',
    '.DS_Store', 'Thumbs.db'
  ].freeze

  module_function

  def ephemeral_path?(path)
    base = File.basename(path.to_s)
    EPHEMERAL_BASENAME_GLOBS.any? { |pattern| File.fnmatch(pattern, base) }
  end

  def execute_commits(commits)
    committed = false
    commits.each { |commit| committed = true if execute_single_commit(commit) }
    committed
  end

  def execute_single_commit(commit)
    files = committable_files(commit)
    return false if files.empty? || commit["message"].to_s.strip.empty?

    run_git_add(files)
    staged = staged_among(files)
    return false if staged.empty?

    run_git_commit(commit["message"].to_s.strip, staged)
  end

  def committable_files(commit)
    extract_commit_files(commit).reject { |path| ephemeral_path?(path) }
  end

  # name-only omits rename/copy sources; name-status lists both sides. If either side is
  # planned, commit both so a rename is not split into add + leftover deletion.
  def staged_among(planned)
    out, _, status = Open3.capture3("git", "diff", "--cached", "--name-status", "-z")
    return [] unless status.success?

    cached, couples = parse_cached_name_status(out)
    picked = planned.select { |path| cached.include?(path) }.to_set
    couples.each { |pair| picked.merge(pair) if pair.any? { |path| picked.include?(path) } }
    picked.to_a
  end

  def parse_cached_name_status(raw)
    cached = []
    couples = []
    tokens = raw.to_s.split("\0").reject(&:empty?)
    i = 0
    while i < tokens.size
      code = tokens[i]
      i += 1
      take = code.match?(/\A[RC]/) ? 2 : 1
      paths = tokens[i, take]
      i += take
      cached.concat(paths)
      couples << paths if take == 2 && paths.size == 2
    end
    [cached.to_set, couples]
  end

  def extract_commit_files(commit)
    Array(commit["files"]).map(&:to_s).reject(&:empty?)
  end

  def run_git_add(files)
    existing = files.select { |f| File.exist?(f) }
    deleted = files.reject { |f| File.exist?(f) }
    run_git_add_existing(existing)
    run_git_add_deleted(deleted)
  end

  def run_git_add_existing(paths)
    return if paths.empty?

    add_cmd = ["git", "add", *paths].map { |p| Shellwords.escape(p) }.join(" ")
    puts "Running: #{add_cmd}".green
    abort_staging unless system(add_cmd)
  end

  def resolve_deleted_paths_for_index(paths)
    index_paths = `git ls-files`.split("\n")
    paths.filter_map do |path|
      next path if index_paths.include?(path)
      next unless path.end_with?(".")

      json_path = "#{path.sub(/\.$/, "")}.json"
      json_path if index_paths.include?(json_path)
    end.uniq
  end

  def run_git_add_deleted(paths)
    return if paths.empty?

    resolved = resolve_deleted_paths_for_index(paths)
    return if resolved.empty?

    add_u_cmd = ["git", "add", "-u", "--", *resolved].map { |p| Shellwords.escape(p) }.join(" ")
    puts "Running: #{add_u_cmd}".green
    abort_staging unless system(add_u_cmd)
  end

  def abort_staging
    warn "Staging failed; commit skipped.".red
    exit 1
  end

  def run_git_commit(message, files)
    commit_cmd = ["git", "commit", "-m", message, "--", *files].map { |p| Shellwords.escape(p) }.join(" ")
    puts "Running: #{commit_cmd}".green
    system(commit_cmd)
  end
end
