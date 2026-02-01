# frozen_string_literal: true

require 'shellwords'

# Decides if a refactor step is needed from changed-file line counts (no LLM).
# Rule: refactor needed when any changed .rb file exceeds RB_LINE_THRESHOLD lines
# or any changed .mm file exceeds MM_LINE_THRESHOLD lines. Only changed files count.
module RefactorNeededCheck
  RB_LINE_THRESHOLD = 800
  MM_LINE_THRESHOLD = 2000

  module_function

  # Returns list of changed files with line counts. Each entry is { path: String, lines: Integer }.
  # path is relative to project_root. Only files present in git diff (staged or unstaged) are included.
  def changed_files(project_root)
    root = project_root.to_s
    names = `git -C #{Shellwords.escape(root)} diff --name-only 2>#{File::NULL}`.split("\n")
    names.concat(`git -C #{Shellwords.escape(root)} diff --name-only --cached 2>#{File::NULL}`.split("\n"))
    names.uniq!
    names.filter_map do |rel_path|
      full = File.join(root, rel_path)
      next unless File.file?(full)

      lines = File.read(full).lines.size
      { path: rel_path, lines: lines }
    rescue SystemCallError
      nil
    end
  end

  # True when any changed .rb has more than RB_LINE_THRESHOLD lines or any changed .mm has more than MM_LINE_THRESHOLD.
  def refactor_needed?(changed_files_list)
    changed_files_list.any? do |entry|
      path = entry[:path].to_s
      lines = entry[:lines].to_i
      (path.end_with?('.rb') && lines > RB_LINE_THRESHOLD) ||
        (path.end_with?('.mm') && lines > MM_LINE_THRESHOLD)
    end
  end
end
