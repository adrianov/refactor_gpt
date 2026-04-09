#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/loader"
require "colorize"
require "shellwords"

# Resolves git merge conflicts using LLM. Edits conflicted files in-place and stages them.
class ConflictResolver
  include AgentsFileHandler

  CONFLICT_START = /^<<<<<<< /
  CONFLICT_MID   = /^=======/
  CONFLICT_END   = /^>>>>>>> /

  def initialize(debug: false)
    @debug = debug
    @client = OpenAiClient.new(debug: debug)
  end

  def run
    root = git_root
    Dir.chdir(root)
    abort "Not in a conflicted merge state.".yellow unless merge_in_progress?(root) || conflicted_files.any?
    resolve_all
  end

  private

  def git_root
    root = `git rev-parse --show-toplevel 2>/dev/null`.strip
    abort "Not in a git repository.".red unless $?.success? && !root.empty?
    root
  end

  def merge_in_progress?(root)
    git_dir = git_dir(root)
    File.exist?(File.join(git_dir, "MERGE_HEAD")) ||
      File.exist?(File.join(git_dir, "rebase-merge")) ||
      File.exist?(File.join(git_dir, "rebase-apply"))
  end

  def git_dir(root)
    dir = `git rev-parse --git-dir 2>/dev/null`.strip
    abort "Could not determine git metadata directory.".red unless $?.success? && !dir.empty?

    File.expand_path(dir, root)
  end

  def resolve_all
    files = conflicted_files
    abort "No conflicted files found.".yellow if files.empty?

    file_contents = read_files(reference_files(files))
    puts "Resolving #{files.size} conflicted file(s)...".cyan
    files.each { |f| resolve_file(f, file_contents) }
    puts "\nAll conflicts resolved and staged. Review and commit when ready.".green
  end

  def conflicted_files
    `git diff --name-only --diff-filter=U`.split("\n").map(&:strip).reject(&:empty?)
  end

  def reference_files(files)
    staged = `git diff --name-only --cached`.split("\n")
    unstaged = `git diff --name-only`.split("\n")
    (files + staged + unstaged).map(&:strip).reject(&:empty?).uniq.select { |path| File.file?(path) }
  end

  def read_files(paths)
    paths.each_with_object({}) { |p, h| h[p] = File.read(p) }
  end

  def resolve_file(path, all_contents)
    content = all_contents[path]
    return puts "  #{path}: no conflict markers, skipping.".yellow unless has_conflict_markers?(content)

    puts "  Resolving #{path}...".blue
    resolved = ask_llm(path, content, all_contents)
    return warn "  #{path}: LLM returned empty content, skipping.".red if resolved.nil? || resolved.strip.empty?

    write_and_stage(path, resolved)
  end

  def write_and_stage(path, content)
    File.write(path, content)
    system("git add #{Shellwords.escape(path)}")
    puts "  #{path}: resolved and staged.".green
  end

  def has_conflict_markers?(content)
    content.match?(CONFLICT_START) && content.match?(CONFLICT_MID) && content.match?(CONFLICT_END)
  end

  def ask_llm(path, content, all_contents)
    messages = [
      {role: "system", content: system_instruction},
      {role: "user", content: user_prompt(path, content, all_contents)}
    ]
    response = @client.ask(messages, title: "Resolving #{File.basename(path)}".cyan)
    extract_resolved(response, path)
  end

  def system_instruction
    agents = load_agents_file(Dir.pwd)
    project_context = agents.empty? ? "" : "Project guidelines:\n#{agents}\n\n"

    <<~TEXT.strip
      #{project_context}You are an expert developer resolving git merge conflicts.

      For each conflict block:
      - Keep the correct side when one side is clearly right.
      - Merge both sides when each contains distinct, non-duplicate changes.
      - Remove all conflict markers (<<<<<<, =======, >>>>>>>).
      - Leave all non-conflicting code untouched.

      The resolved file must:
      - Be syntactically valid and pass linting under the project's rules.
      - Satisfy project specs and conventions defined in the guidelines above.
      - Compile and run without errors introduced by the merge.

      Return ONLY the complete resolved file content — no explanation, no markdown fences, no surrounding text.
    TEXT
  end

  def user_prompt(path, content, all_contents)
    context = all_contents.reject { |p, _| p == path }
    context_section = context.map { |p, c| "<context filename=\"#{p}\">\n#{c}\n</context>" }.join("\n\n")

    <<~TEXT
      Resolve all merge conflicts in this file: #{path}

      <conflicted_file filename="#{path}">
      #{content}
      </conflicted_file>
      #{context_section.empty? ? "" : "\nOther files in the merge for context (do not modify):\n\n#{context_section}"}
    TEXT
  end

  def extract_resolved(response, path)
    return nil if response.nil? || response.strip.empty?

    cleaned = response.strip
    if cleaned.start_with?("```")
      lines = cleaned.split("\n")
      lines.shift
      lines.pop while lines.last&.start_with?("```")
      cleaned = lines.join("\n")
    end

    if has_conflict_markers?(cleaned)
      warn "  #{path}: LLM response still contains conflict markers.".red
      return nil
    end

    cleaned
  end
end

# Entry point
CompletionNotifier.setup_exit_hook

debug = ARGV.include?("--debug") || ARGV.include?("-d")
ConflictResolver.new(debug: debug).run
