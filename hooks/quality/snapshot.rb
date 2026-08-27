# frozen_string_literal: true

require 'json'
require 'digest'
require 'find'
require 'fileutils'

module Quality
  # Workspace change marker built from the filesystem alone: every stop
  # fingerprints each root as {relative path => mtime} and diffs it against
  # the baseline persisted at the last clean cycle end. No transcript reads,
  # no git status lists, no file-content hashing anywhere in the pipeline.
  #
  # .gitignore semantics come straight from `git ls-files --cached --others
  # --exclude-standard` run at the enclosing repo toplevel; roots outside any
  # repo fall back to a walk pruning VCS internals and common generated dirs.
  # Cost is one stat per tracked file per stop, independent of file sizes,
  # because contents are never opened. Accepted tradeoff for a lint gate: an
  # edit written with a preserved older mtime (cp -p, rsync -a, tar) reads as
  # unchanged until something touches the file again.
  module Snapshots
    # Pruned only in ignore-less roots; real projects get exact semantics
    # from their own .gitignore via git ls-files.
    WALK_PRUNE = %w[
      .git .svn .hg node_modules __pycache__ .tox .cache log tmp coverage
    ].freeze

    def changed_files
      @changed_files ||= begin
        paths = detect_changed_paths
        log_action('snapshot', roots: @roots.size, changed: paths.size)
        paths.freeze
      end
    end

    # Advances the baseline so the next idle stop diffs clean. Wired at the
    # single clean-cycle exit point; restarts and stalls skip it deliberately.
    def mark_baseline!
      path = workspace_snapshot_file
      tmp = "#{path}.#{Process.pid}.tmp"
      File.write(tmp, JSON.generate('roots' => collect_tables(@roots)))
      File.rename(tmp, path)
    rescue StandardError
      nil
    end

    def detect_changed_paths
      FileUtils.mkdir_p(Quality::STATE)
      current = collect_tables(@roots)
      stored = load_snapshot_roots
      @roots.flat_map { |root| root_diff(root, current[root], stored[root]) }.sort
    end

    # A path moved when its fingerprint differs from, or is missing next to,
    # the persisted baseline table.
    def root_diff(root, mine, was)
      mine ||= {}
      was ||= {}
      moved = mine.filter_map { |rel, mt| File.join(root, rel) if was[rel] != mt }
      gone = (was.keys - mine.keys).map { |rel| File.join(root, rel) }
      moved + gone
    end

    def collect_tables(roots)
      roots.each_with_object({}) do |root, all|
        next all unless File.directory?(root)

        top = git_root(root)
        all[root] = table_for(top || root, git_listing_rels(top, root))
      end
    end

    def table_for(base, rels)
      rels.each_with_object({}) do |rel, table|
        abs = File.join(base, rel)
        next if under_hooks?(abs) || File.symlink?(abs)

        begin
          table[rel] = File.stat(abs).mtime.to_f
        rescue SystemCallError
          nil
        end
      end
    end

    private

    # Paths under a git repo: ignore rules resolved by git itself at the
    # enclosing toplevel; several roots sharing one repo reuse the listing.
    def git_listing_rels(top, root)
      return walked_rels(root) unless top

      prefix = root == top ? '' : "#{rel_to(top, root) || ''}/"
      rels_under(git_listing(top), prefix)
    end

    # One listing per repo toplevel per stop: nested roots share it.
    def git_listing(top)
      (@git_listings ||= {})[top] ||= capture(
        'git', '-C', top, 'ls-files', '-z', '--cached', '--others', '--exclude-standard'
      )[0].to_s.split("\0").reject(&:empty?)
    end

    # Nested roots key their tables relative to themselves, not the repo.
    def rels_under(listing, prefix)
      return listing.dup if prefix.empty?

      listing.select { |f| f.start_with?(prefix) }.map { |f| f[prefix.length..] }
    end

    def walked_rels(root)
      rels = []
      Find.find(root) do |path|
        if File.directory?(path)
          Find.prune if WALK_PRUNE.include?(File.basename(path))
          next
        end

        rels << rel_to(root, path)
      end
      rels.compact
    end

    # Hook-owned files (state under refactor_gpt/hooks) flip constantly and
    # sit inside scanned dev workspaces; excluding them prevents self-triggers.
    def under_hooks?(abs)
      abs == HOOKS || abs.start_with?("#{HOOKS}/")
    end

    def load_snapshot_roots
      JSON.parse(File.read(workspace_snapshot_file))['roots'] || {}
    rescue StandardError
      {}
    end
  end
end
