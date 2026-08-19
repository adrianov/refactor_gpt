# frozen_string_literal: true

require "open3"
require "shellwords"
require "colorize"

# Captures uncommitted unified diffs and MR numstat for git_commit_gpt planning.
class GitCommitDiffCapture
  DIFF_PAYLOAD_NOTE_RESERVE_CHARS = 2048
  # User review: drop only -W when a path's function-context diff is this long or longer.
  REVIEW_DIFF_MAX_LINES = 500
  REVIEW_DIFF_SHORT_OPTS = (GitCommitDiffCompaction::FULL_OPTS - %w[-W]).freeze
  # Git’s canonical empty tree — valid diff base when there is no HEAD (initial / orphan import).
  GIT_EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

  def initialize(pathspecs: [])
    @pathspecs = Array(pathspecs)
  end

  def show_if_needed(show_diff)
    show_uncommitted_diff if show_diff
  end

  def fetch_mr_numstat
    return "" unless system("git rev-parse -q --verify origin/HEAD >#{File::NULL} 2>&1")

    out, _, st = Open3.capture3("git", "diff", "--numstat", "-w", "origin/HEAD...", *pathspec_args)
    return "" unless st.success?

    Utility.utf8_safe(out).strip
  end

  def compact_uncommitted_diff(limit_chars)
    compaction_cap = [limit_chars - DIFF_PAYLOAD_NOTE_RESERVE_CHARS, 0].max
    result = GitCommitDiffCompaction.build(
      ref_spec: worktree_uncommitted_ancestor, limit_chars: compaction_cap, pathspecs: @pathspecs
    )
    note = format_budget_omitted_paths_note(result.budget_omitted_paths, DIFF_PAYLOAD_NOTE_RESERVE_CHARS)
    body = Utility.utf8_safe(result.body)
    return body if note.empty?

    Utility.utf8_join("\n\n", body, note)
  end

  def fallback_uncommitted_diff
    try_git_unified_against(worktree_uncommitted_ancestor) || try_combined_index_and_worktree
  end

  def abort_without_uncommitted_diff
    warn "Failed to capture uncommitted diff for analysis".red
    err = @last_git_diff_stderr.to_s.strip
    warn err unless err.empty?
    exit 1
  end

  private

  def pathspec_args
    GitPathspec.args(@pathspecs)
  end

  def worktree_uncommitted_ancestor
    head_exists? ? "HEAD" : GIT_EMPTY_TREE
  end

  def head_exists?
    system("git rev-parse -q --verify HEAD >#{File::NULL} 2>&1")
  end

  def try_git_unified_against(against = nil)
    out, err = GitPerPathUnifiedDiff.capture_with_stderr(against, pathspecs: @pathspecs)
    return out if out

    @last_git_diff_stderr = err.to_s
    nil
  end

  def try_combined_index_and_worktree
    cached = try_git_unified_against("--cached")
    worktree = try_git_unified_against
    return nil unless cached && worktree

    Utility.utf8_join(
      "\n\n",
      [cached, worktree].map { |s| Utility.utf8_safe(s) }.reject { |s| s.strip.empty? }
    )
  end

  def show_uncommitted_diff
    ref = worktree_uncommitted_ancestor
    extra = pathspec_args
    puts "Uncommitted changes:".cyan
    return puts if show_review_diffs(ref)

    full = GitCommitDiffCompaction::FULL_OPTS
    light = GitCommitDiffCompaction::LIGHT_UNIFIED_OPTS
    puts ["git", "diff", *full, ref, *extra].shelljoin.cyan
    shown = system("git", "diff", *full, ref, *extra)
    shown ||= system("git", "diff", *light, ref, *extra)
    system("git", "diff", *(%w[--no-ext-diff] + light + [ref]), *extra) unless shown
    puts
  end

  # Prefer -w -W; omit -W only for paths whose function-context diff is REVIEW_DIFF_MAX_LINES+.
  def show_review_diffs(ref)
    out, _, st = Open3.capture3("git", "diff", "--name-only", "-z", ref, *pathspec_args)
    return false unless st.success?

    paths = out.split("\0").reject(&:empty?)
    return false if paths.empty?

    with_w, without_w = paths.partition { |path| function_context?(ref, path) }
    show_diff_group(ref, GitCommitDiffCompaction::FULL_OPTS, with_w)
    show_diff_group(ref, REVIEW_DIFF_SHORT_OPTS, without_w)
    true
  end

  def function_context?(ref, path)
    measured, _, ok = Open3.capture3("git", "diff", *GitCommitDiffCompaction::FULL_OPTS, ref, "--", path)
    !(ok && measured.lines.size >= REVIEW_DIFF_MAX_LINES)
  end

  def show_diff_group(ref, opts, paths)
    return if paths.empty?

    cmd = ["git", "diff", *opts, ref, "--", *paths]
    puts cmd.shelljoin.cyan
    system(*cmd)
  end

  def format_budget_omitted_paths_note(paths, max_chars)
    return "" if paths.empty? || max_chars < 64

    uniq_sorted = paths.map { |p| Utility.utf8_safe(p) }.uniq.sort
    header = <<~NOTE.rstrip
      ---
      Unified diff omitted under size limits for these paths (insert/delete counts remain in the numstat block above).
      Each path is still an uncommitted change: assign it to exactly one commit with related files, and include it in
      quality_assessment and warnings using git status, filename, and numstat when patch text is absent.
    NOTE
    body = Utility.utf8_join("\n", uniq_sorted)
    text = Utility.utf8_join("\n", header, body)
    return text if text.length <= max_chars

    overhead = 48
    cut = [max_chars - overhead, 0].max
    Utility.utf8_join("\n", text[0, cut], "… (#{uniq_sorted.size} paths total)")
  end
end
