# frozen_string_literal: true

require "open3"
require "colorize"

# Captures uncommitted unified diffs and MR numstat for git_commit_gpt planning.
module GitCommitDiffCapture
  DIFF_PAYLOAD_NOTE_RESERVE_CHARS = 2048
  DIFF_OPTS = GitCommitDiffCompaction::FULL_OPTS.join(' ')
  DIFF_OPTS_MINIMAL = GitCommitDiffCompaction::LIGHT_UNIFIED_OPTS.join(' ')
  # Git’s canonical empty tree — valid diff base when there is no HEAD (initial / orphan import).
  GIT_EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

  module_function

  def show_if_needed(show_diff)
    show_uncommitted_diff if show_diff
  end

  def fetch_mr_numstat
    return "" unless system("git rev-parse -q --verify origin/HEAD >#{File::NULL} 2>&1")

    out, _, st = Open3.capture3("git", "diff", "--numstat", "-w", "origin/HEAD...")
    return "" unless st.success?

    out.strip
  end

  def compact_uncommitted_diff(limit_chars)
    compaction_cap = [limit_chars - DIFF_PAYLOAD_NOTE_RESERVE_CHARS, 0].max
    result = GitCommitDiffCompaction.build(ref_spec: worktree_uncommitted_ancestor, limit_chars: compaction_cap)
    note = format_budget_omitted_paths_note(result.budget_omitted_paths, DIFF_PAYLOAD_NOTE_RESERVE_CHARS)
    note.empty? ? result.body : "#{result.body}\n\n#{note}"
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

  def worktree_uncommitted_ancestor
    head_exists? ? "HEAD" : GIT_EMPTY_TREE
  end

  def head_exists?
    system("git rev-parse -q --verify HEAD >#{File::NULL} 2>&1")
  end

  def try_git_unified_against(against = nil)
    out, err = GitPerPathUnifiedDiff.capture_with_stderr(against)
    return out if out

    @last_git_diff_stderr = err.to_s
    nil
  end

  def try_combined_index_and_worktree
    cached = try_git_unified_against("--cached")
    worktree = try_git_unified_against
    return nil unless cached && worktree

    [cached, worktree].map(&:to_s).reject { |s| s.strip.empty? }.join("\n\n")
  end

  def show_uncommitted_diff
    ref = worktree_uncommitted_ancestor
    puts "Uncommitted changes:".cyan
    puts "git diff #{DIFF_OPTS} #{ref}".cyan
    shown = system("git", "diff", *DIFF_OPTS.split, ref)
    shown ||= system("git", "diff", *DIFF_OPTS_MINIMAL.split, ref)
    system("git", "diff", *(%w[--no-ext-diff] + DIFF_OPTS_MINIMAL.split + [ref])) unless shown
    puts
  end

  def format_budget_omitted_paths_note(paths, max_chars)
    return '' if paths.empty? || max_chars < 64

    uniq_sorted = paths.uniq.sort
    header = <<~NOTE.rstrip
      ---
      Unified diff omitted under size limits for these paths (insert/delete counts remain in the numstat block above).
      Each path is still an uncommitted change: assign it to exactly one commit with related files, and include it in
      quality_assessment and warnings using git status, filename, and numstat when patch text is absent.
    NOTE
    body = uniq_sorted.join("\n")
    text = "#{header}\n#{body}"
    return text if text.length <= max_chars

    overhead = 48
    cut = [max_chars - overhead, 0].max
    "#{text[0, cut]}\n… (#{uniq_sorted.size} paths total)\n"
  end
end
