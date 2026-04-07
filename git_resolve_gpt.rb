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
    env = ENV.to_h.merge(load_env_vars)
    model = LlmRouter.default_model(env)
    config = LlmRouter.config_for_model(model, env)
    abort "No API configuration found. Set MODEL and access token in .env".red unless config

    @client = build_client(config)
  end

  def run
    root = git_root
    Dir.chdir(root)
    abort "Not in a conflicted merge state.".yellow unless merge_in_progress?(root)

    files = conflicted_files
    abort "No conflicted files found.".yellow if files.empty?

    puts "Resolving #{files.size} conflicted file(s)...".cyan
    files.each { |f| resolve_file(f) }
    puts "\nAll conflicts resolved and staged. Review and commit when ready.".green
  end

  private

  def build_client(config)
    common = {model: config[:model], debug: @debug, api_base_url: config[:base_url], api_key: config[:access_token]}
    config[:backend] == :gemini ? AskGeminiClient.new(**common, progress: true) : AskGptClient.new(**common)
  end

  def git_root
    root = `git rev-parse --show-toplevel 2>/dev/null`.strip
    abort "Not in a git repository.".red unless $?.success? && !root.empty?
    root
  end

  def merge_in_progress?(root)
    File.exist?(File.join(root, ".git", "MERGE_HEAD")) ||
      File.exist?(File.join(root, ".git", "rebase-merge")) ||
      File.exist?(File.join(root, ".git", "rebase-apply"))
  end

  def conflicted_files
    `git diff --name-only --diff-filter=U`.split("\n").map(&:strip).reject(&:empty?)
  end

  def resolve_file(path)
    content = File.read(path)
    return puts "  #{path}: no conflict markers, skipping.".yellow unless has_conflict_markers?(content)

    puts "  Resolving #{path}...".blue
    resolved = ask_llm(path, content)
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

  def ask_llm(path, content)
    messages = [
      {role: "system", content: system_instruction},
      {role: "user", content: user_prompt(path, content)}
    ]
    response = @client.ask(messages, title: "Resolving #{File.basename(path)}".cyan)
    extract_resolved(response, path)
  end

  def system_instruction
    <<~TEXT.strip
      You are an expert developer resolving git merge conflicts.
      When given a file with conflict markers, produce the fully resolved version by:
      - Choosing the correct code from each conflict block based on intent and context
      - Merging both sides when both contain useful, non-duplicate changes
      - Removing all conflict markers (<<<<<<, =======, >>>>>>>)
      - Preserving all non-conflicting code exactly as-is

      Return ONLY the resolved file content, with no explanation, no markdown fences, no extra text.
      The output must be the exact bytes to write to disk.
    TEXT
  end

  def user_prompt(path, content)
    <<~TEXT
      Resolve all merge conflicts in this file: #{path}

      #{content}
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
