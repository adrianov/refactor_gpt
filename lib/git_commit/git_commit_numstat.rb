# frozen_string_literal: true

require "open3"

# Leading `git diff --numstat` block for git_commit_gpt compaction (with optional pathspecs).
module GitCommitNumstat
  module_function

  def prefix(ref_spec, pathspecs: [], ignore_whitespace: true, header_line: nil)
    cmd = %w[git diff --numstat]
    cmd << "-w" if ignore_whitespace
    cmd << ref_spec.to_s
    cmd.concat(GitPathspec.args(pathspecs))
    out, _, status = Open3.capture3(*cmd)
    return "" unless status.success?

    stripped = Utility.utf8_safe(out).strip
    return "" if stripped.empty?

    flag = ignore_whitespace ? " -w" : ""
    lines = []
    lines << header_line if header_line
    lines << "(all paths: git diff --numstat#{flag} #{ref_spec})"
    "#{lines.join("\n")}\n#{stripped}\n"
  end
end
