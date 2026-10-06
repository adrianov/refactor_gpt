# frozen_string_literal: true

require 'open3'

# Commit where the current branch split from the default branch.
# First existing ref wins: origin/HEAD, origin/master, origin/main, master, main.
module BranchPoint
  BASE_REFS = %w[origin/HEAD origin/master origin/main master main].freeze

  module_function

  # [rev, label]. Label is HEAD when this branch has not diverged.
  def resolve(root = nil)
    BASE_REFS.each do |ref|
      sha = merge_base(root, ref)
      next unless sha
      return [sha, 'HEAD'] if sha == head_sha(root)

      return [sha, "merge-base with #{ref_label(root, ref)} (#{sha[0, 12]})"]
    end
    ['HEAD', 'HEAD']
  end

  # SHA to diff against, or nil when HEAD has not diverged from the branch point.
  def rev(root = nil)
    sha, label = resolve(root)
    label == 'HEAD' ? nil : sha
  end

  def merge_base(root, ref)
    out, _, status = git(root, 'merge-base', ref, 'HEAD')
    out.strip if status.success? && !out.strip.empty?
  end

  def head_sha(root)
    out, _, status = git(root, 'rev-parse', 'HEAD')
    status.success? ? out.strip : ''
  end

  def ref_label(root, ref)
    return ref unless ref == 'origin/HEAD'

    out, _, status = git(root, 'rev-parse', '--abbrev-ref', 'origin/HEAD')
    status.success? && !out.strip.empty? ? out.strip : ref
  end

  def git(root, *args)
    Open3.capture3(*(['git'] + (root ? ['-C', root] : []) + args))
  end
end
