# frozen_string_literal: true

module Quality
  # Change detection: git is the source of truth for every workspace root
  # inside a repository. The reported set is the uncommitted work against
  # HEAD (staged, unstaged, deleted) plus untracked non-ignored files —
  # exactly what the next commit would take. Roots outside any repo are
  # skipped. No snapshots, no baselines, no state files.
  module GitChanges
    def changed_files
      @changed_files ||= detect_changed_paths.freeze
    end

    def detect_changed_paths
      paths = @roots.filter_map { |root| git_root_paths(root) }.flatten.sort
      log_action('changes', roots: @roots.size, changed: paths.size)
      paths
    end

    private

    # Uncommitted work against HEAD plus untracked files, mapped from
    # repo-relative paths into the root; nested roots see their slice only.
    def git_root_paths(root)
      top = git_root(root)
      return nil unless top

      prefix = root == top ? '' : "#{rel_to(top, root)}/"
      rels_under(head_diff_rels(top) + untracked_rels(top), prefix)
            .map { |rel| File.join(root, rel) }
    end

    def head_diff_rels(top)
      out, _err, code = capture('git', '-C', top, 'diff', '--name-only', '-z', 'HEAD')
      code.zero? ? out.split("\0").reject(&:empty?) : []
    end

    def untracked_rels(top)
      out, _err, code = capture('git', '-C', top, 'ls-files', '-z', '--others', '--exclude-standard')
      code.zero? ? out.split("\0").reject(&:empty?) : []
    end

    # Nested roots key their paths relative to themselves, not the repo.
    def rels_under(listing, prefix)
      return listing.dup if prefix.empty?

      listing.select { |f| f.start_with?(prefix) }.map { |f| f[prefix.length..] }
    end
  end
end
