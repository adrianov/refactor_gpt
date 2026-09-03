#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/loader"
require "colorize"
require "shellwords"

# Resolves git merge conflicts using LLM. Edits conflicted files in-place and stages them.
class ConflictResolver
  include AgentsFileHandler
  include ConflictResolveGit

  CONFLICT_START = /^<<<<<<< /
  CONFLICT_MID   = /^=======/
  CONFLICT_END   = /^>>>>>>> /

  def initialize(debug: false)
    @debug = debug
    @client = OpenrouterClient.new(debug: debug)
  end

  def run
    root = git_root
    Dir.chdir(root)
    abort "Not in a conflicted merge state.".yellow unless merge_in_progress?(root) || conflicted_files.any?
    resolve_all
  end

  private

  def resolve_all
    files = conflicted_files
    abort "No conflicted files found.".yellow if files.empty?

    file_contents = read_files(reference_files(files))
    commit_context = conflict_commit_context
    puts "Resolving #{files.size} conflicted file(s)...".cyan
    files.each { |f| resolve_file(f, file_contents, commit_context) }
    puts "\nAll conflicts resolved and staged. Review and commit when ready.".green
  end

  def resolve_file(path, all_contents, commit_context)
    content = all_contents[path]
    return puts "  #{path}: no conflict markers, skipping.".yellow unless has_conflict_markers?(content)

    puts "  Resolving #{path}...".blue
    resolved = ask_llm(path, content, all_contents, commit_context)
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

  def ask_llm(path, content, all_contents, commit_context)
    messages = [
      {role: "system", content: system_instruction},
      {role: "user", content: user_prompt(path, content, all_contents, commit_context)}
    ]
    extract_resolved(@client.ask(messages, title: "Resolving #{File.basename(path)}".cyan), path)
  end

  def system_instruction
    ConflictResolvePrompt.system_instruction(load_agents_file(Dir.pwd))
  end

  def user_prompt(path, content, all_contents, commit_context)
    ConflictResolvePrompt.user_prompt(path, content, all_contents, commit_context)
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
