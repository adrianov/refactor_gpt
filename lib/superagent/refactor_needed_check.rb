# frozen_string_literal: true

require 'shellwords'
require_relative 'modified_files_tracker'

# Decides if a refactor step is needed from changed-file line counts or file count (no LLM).
# Rules: refactor when any file exceeds LINE_THRESHOLDS, or when file count >= SHOTGUN_FILE_COUNT_THRESHOLD.
# For triggers we use mtime snapshot (before/after run) so only files edited in the current run count.
module RefactorNeededCheck
  # Refactor when this many or more files changed for one business rule (shotgun surgery).
  SHOTGUN_FILE_COUNT_THRESHOLD = 6

  # Extension => line limit (refactor when file has >= this many lines).
  LINE_THRESHOLDS = {
    '.rb' => 800, '.py' => 800, '.php' => 800,
    '.js' => 1000, '.ts' => 1000, '.jsx' => 1000, '.tsx' => 1000,
    '.go' => 1000, '.rs' => 1000,
    '.java' => 1200, '.kt' => 1200, '.swift' => 1200, '.cs' => 1200, '.scala' => 1200,
    '.c' => 1500, '.h' => 1500, '.cpp' => 1500, '.cc' => 1500, '.hpp' => 1500,
    '.m' => 2000, '.mm' => 2000
  }.freeze

  module_function

  # Returns Hash path (relative) => mtime (Time) for code files that are git-changed or untracked.
  # Capture before implementation run; pass to changed_files_since after run for trigger-only stats.
  def mtimes_snapshot(project_root)
    root = project_root.to_s
    names = git_changed_and_untracked_names(root).select { |p| ModifiedFilesTracker.code_file?(p) }
    names.filter_map do |rel_path|
      full = File.join(root, rel_path)
      [rel_path, File.mtime(full)] if File.file?(full)
    end.to_h
  rescue SystemCallError
    {}
  end

  # Returns changed files (path + lines) for this run only: mtime > snapshot, new, or deleted.
  # mtimes_before: from mtimes_snapshot(root) before run. If nil, falls back to all git-changed (legacy).
  def changed_files_since(project_root, mtimes_before)
    root = project_root.to_s
    names = code_file_names_since(root)
    return names.filter_map { |rel_path| file_entry(root, rel_path) } if mtimes_before.nil? || mtimes_before.empty?

    names.filter_map do |rel_path|
      entry_for_run(root, rel_path, mtimes_before)
    end
  rescue SystemCallError
    []
  end

  # Returns list of changed files with line counts. Each entry is { path: String, lines: Integer }.
  # path is relative to project_root. Includes git diff (staged/unstaged) and untracked files.
  def changed_files(project_root)
    root = project_root.to_s
    names = git_changed_and_untracked_names(root)
    names.filter_map { |rel_path| file_entry(root, rel_path) }
  end

  def git_changed_and_untracked_names(root)
    esc = Shellwords.escape(root)
    names = `git -C #{esc} diff --name-only 2>#{File::NULL}`.split("\n")
    names.concat(`git -C #{esc} diff --name-only --cached 2>#{File::NULL}`.split("\n"))
    names.concat(`git -C #{esc} ls-files --others --exclude-standard 2>#{File::NULL}`.split("\n"))
    names.uniq
  end

  def file_entry(root, rel_path)
    full = File.join(root, rel_path)
    return nil unless File.file?(full)

    { path: rel_path, lines: File.read(full).lines.size }
  rescue SystemCallError
    nil
  end

  def code_file_names_since(root)
    git_changed_and_untracked_names(root).select { |p| ModifiedFilesTracker.code_file?(p) }
  end

  def entry_for_run(root, rel_path, mtimes_before)
    full = File.join(root, rel_path)
    return { path: rel_path, lines: 0 } if !File.file?(full) && mtimes_before.key?(rel_path) # deleted in run
    return nil unless File.file?(full)

    prev = mtimes_before[rel_path]
    return nil unless prev.nil? || File.mtime(full) > prev

    file_entry(root, rel_path)
  end

  private :git_changed_and_untracked_names, :file_entry, :code_file_names_since, :entry_for_run

  # True when any changed file exceeds line threshold or when changed file count >= SHOTGUN_FILE_COUNT_THRESHOLD.
  def refactor_needed?(changed_files_list)
    files_triggering_refactor(changed_files_list).any? || shotgun_triggered?(changed_files_list)
  end

  # True when SHOTGUN_FILE_COUNT_THRESHOLD or more files changed (shotgun surgery).
  def shotgun_triggered?(changed_files_list)
    (changed_files_list || []).size >= SHOTGUN_FILE_COUNT_THRESHOLD
  end

  # Returns entries that triggered refactor: [{ path:, lines:, limit: }, ...].
  # Use when building the refactor prompt so the model knows which files and why.
  def files_triggering_refactor(changed_files_list)
    changed_files_list.filter_map do |entry|
      path = entry[:path].to_s
      lines = entry[:lines].to_i
      ext, limit = LINE_THRESHOLDS.find { |e, l| path.end_with?(e) && lines >= l }
      ext ? { path: path, lines: lines, limit: limit } : nil
    end
  end
end
