# frozen_string_literal: true

require 'open3'

# Commit where the current branch split from the default branch.
# First existing ref wins: origin/HEAD, origin/master, origin/main, master, main.
module BranchPoint
  BASE_REFS = %w[origin/HEAD origin/master origin/main master main].freeze

  module_function

  def merge_base(root, ref)
    out, _, status = git(root, 'merge-base', ref, 'HEAD')
    out.strip if status.success? && !out.strip.empty?
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
