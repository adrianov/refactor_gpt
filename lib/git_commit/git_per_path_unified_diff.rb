# frozen_string_literal: true

require 'open3'

# Runs the same unified-diff option cascade as legacy whole-repo git diff, but one path at a time
# (no single `git diff` over the entire tree). Used by git_commit_gpt try_git_unified_against.
class GitPerPathUnifiedDiff
  class << self
    def capture_with_stderr(against, pathspecs: [])
      paths = diff_paths(against, pathspecs)
      return ['', ''] if paths.empty?

      last_err = +''
      opt_variants.each do |opts|
        body, err = assemble_paths(against, opts, paths)
        last_err = err if err
        return [body, err] if body
      end
      [nil, last_err]
    end

    private

    def opt_variants
      f = GitCommitDiffCompaction::FULL_OPTS
      l = GitCommitDiffCompaction::LIGHT_UNIFIED_OPTS
      nw_f = GitCommitDiffCompaction::NO_WS_FULL_OPTS
      nw_l = GitCommitDiffCompaction::NO_WS_LIGHT_OPTS
      [
        f,
        l,
        ['--no-ext-diff'] + f,
        ['--no-ext-diff'] + l,
        nw_f,
        nw_l,
        ['--no-ext-diff'] + nw_f,
        ['--no-ext-diff'] + nw_l
      ]
    end

    def diff_paths(against, pathspecs)
      cmd = ['git', 'diff', *name_only_middle(against), '--name-only', '-z', *GitPathspec.args(pathspecs)]
      out, _, st = Open3.capture3(*cmd)
      return [] unless st.success?

      out.split("\0").reject(&:empty?)
    end

    def name_only_middle(against)
      case against
      when nil then []
      when '--cached' then %w[--cached]
      else [against]
      end
    end

    def assemble_paths(against, opts, paths)
      last_err = +''
      chunks = paths.filter_map do |path|
        out, err, st = diff_one(against, opts, path)
        last_err = err.to_s if err
        return [nil, last_err] unless st.success?

        out.strip.empty? ? nil : out
      end
      return [nil, last_err] if chunks.empty?

      [chunks.join("\n\n"), last_err]
    end

    def diff_one(against, opts, path)
      args = ['git', 'diff', *diff_middle_args(against, opts), '--', path]
      Open3.capture3(*args)
    end

    def diff_middle_args(against, opts)
      case against
      when nil then opts
      when '--cached' then ['--cached', *opts]
      else [*opts, against]
      end
    end
  end
end
