# frozen_string_literal: true

module Quality
  # Histogram diff for the VERIFY follow-up.
  # Every main module that differs from the branch point is included:
  # commits on the branch, staged and unstaged edits, and untracked files.
  module VerifyDiff
    # Always pass all four; never drop -w, -W, --histogram, or --no-prefix.
    VERIFY_DIFF_OPTS = %w[-w -W --histogram --no-prefix].freeze
    # First ref that exists wins. origin/HEAD is the remote's default branch.
    BASE_REFS = %w[origin/HEAD origin/master origin/main master main].freeze

    def verify_diff_body(files)
      rows = branch_rows(files)
      return if rows.empty?

      git_diff_attach(diff_text(rows), rows.map { it[:label] }.uniq.join(', '))
    end

    private

    def branch_rows(files)
      repo_roots(files).filter_map { |root| branch_row(root) }
    end

    def repo_roots(files)
      Array(files).filter_map { |f| git_root(File.dirname(f.to_s)) }.uniq
    end

    def branch_row(root)
      rev, label = branch_point(root)
      tracked, untracked = changed_rels(root, rev)
      return if tracked.empty? && untracked.empty?

      { label: label, chunk: combined_diff(root, rev, tracked, untracked) }
    end

    # Tracked names are commits since the branch point plus the worktree
    # (staged and unstaged). Untracked names never show up in git diff.
    def changed_rels(root, rev)
      [
        tracked_rels(root, rev).select { |rel| main_module?(rel) },
        untracked_names(root).select { |rel| main_module?(rel) },
      ]
    end

    def tracked_rels(root, rev)
      (name_only(root, rev, 'HEAD') + name_only(root, 'HEAD')).uniq
    end

    def combined_diff(root, rev, tracked, untracked)
      parts = tracked.empty? ? [] : [diff_paths(root, rev, tracked)]
      untracked.each { |rel| parts << untracked_diff(root, rel) }
      body = parts.compact.reject { |part| part.to_s.empty? }
      body.empty? ? nil : body.join("\n")
    end

    def diff_paths(root, rev, rels)
      out, _, code = capture('git', '-C', root, 'diff', *VERIFY_DIFF_OPTS, rev, '--', *rels)
      out if code.zero? && !out.empty?
    end

    def name_only(root, *revs)
      out, _, code = capture('git', '-C', root, 'diff', '--name-only', '-z', *revs)
      code.zero? ? out.split("\0").reject(&:empty?) : []
    end

    def untracked_names(root)
      out, _, code = capture('git', '-C', root, 'ls-files', '-z', '--others', '--exclude-standard')
      code.zero? ? out.split("\0").reject(&:empty?) : []
    end

    def untracked_diff(root, rel)
      out, _, code = capture(
        'git', '-C', root, 'diff', *VERIFY_DIFF_OPTS, '--no-index', '--', File::NULL, rel
      )
      out if !out.to_s.empty? && [0, 1].include?(code)
    end

    def diff_text(rows)
      chunks = rows.filter_map { it[:chunk] }
      chunks.empty? ? "No net changes since the branch point.\n" : chunks.join("\n")
    end

    def branch_point(root)
      (@branch_points ||= {})[root] ||= resolve_branch_point(root)
    end

    # [rev, label]. Label is HEAD when this branch has not diverged, so the
    # attached text does not claim a merge-base that is just the latest commit.
    def resolve_branch_point(root)
      BASE_REFS.each do |ref|
        next unless ref_commit?(root, ref)

        sha = merge_base(root, ref)
        next unless sha
        return [sha, 'HEAD'] if sha == git_head(root)

        return [sha, "merge-base with #{ref_name(root, ref)} (#{sha[0, 12]})"]
      end
      ['HEAD', 'HEAD']
    end

    def ref_commit?(root, name)
      _, _, code = capture('git', '-C', root, 'rev-parse', '-q', '--verify', "#{name}^{commit}")
      code.zero?
    end

    def merge_base(root, ref)
      out, _, code = capture('git', '-C', root, 'merge-base', ref, 'HEAD')
      out.strip if code.zero? && !out.strip.empty?
    end

    def ref_name(root, ref)
      return ref unless ref == 'origin/HEAD'

      out, _, code = capture('git', '-C', root, 'rev-parse', '--abbrev-ref', 'origin/HEAD')
      code.zero? && !out.strip.empty? ? out.strip : ref
    end

    # Mirror Cursor's Hq() serializer: <git_diff> + indented intro + body.
    def git_diff_attach(diff, base)
      ["<git_diff>", "  #{diff_intro(base)}#{utf8_byte_limit(diff, VERIFY_DIFF_LIMIT)}", '  </git_diff>'].join("\n")
    end

    def diff_intro(base)
      return "Relevant Diff: The following is the git diff of uncommitted changes against HEAD:\n\n" if base == 'HEAD'

      "Relevant Diff: The following is the git diff against #{base}, " \
        "including commits since the branch point and uncommitted changes:\n\n"
    end

    # Cap by bytes without splitting a multibyte UTF-8 character (JSON-safe).
    def utf8_byte_limit(text, limit)
      s = text.to_s
      return s if s.bytesize <= limit

      "#{s.byteslice(0, limit).force_encoding(Encoding::UTF_8).scrub('')}\n... (truncated)"
    end
  end
end
