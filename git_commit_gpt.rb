#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/loader"
require "shellwords"
require "ruby-progressbar"
require "colorize"

# Helper functions
def run_cmd(cmd, capture_output: true)
  if capture_output
    output = `#{cmd}`
    unless $?.success?
      warn "Command failed: #{cmd}".red
      exit 1
    end
    output
  else
    system(cmd)
    unless $?.success?
      warn "Command failed: #{cmd}".red
      exit 1
    end
  end
end

# Get the git root directory
def get_git_root
  root = `git rev-parse --show-toplevel 2>/dev/null`.strip
  unless $?.success?
    puts "Not in a git repository".red
    exit 1
  end
  root
end

def extract_porcelain_filenames(porcelain_output)
  porcelain_output.split("\n").map do |line|
    next nil if line.strip.empty? || line.start_with?("##")

    status_and_path = line.sub(/^.{2}\s+/, "")
    path = status_and_path.include?("->") ? status_and_path.split("->").last.strip : status_and_path
    path.match(/\A"(.*)"\z/) ? Regexp.last_match(1) : path
  end.compact
end

WATCH_INTERVAL = 30

def parse_arguments(args)
  debug_mode = args.include?("--debug")
  watch_mode = args.include?("--watch")
  cli_hint_parts = args.reject { |arg| arg == "--debug" || arg == "--print" || arg == "--watch" }

  [debug_mode, cli_hint_parts.join(" ").to_s.strip, watch_mode]
end

def get_recent_commands
  history_file = detect_history_file
  return "" unless history_file && File.exist?(history_file)

  lines = read_history_file(history_file)
  return "" if lines.empty?

  commands = extract_commands_from_history(lines, history_file)
  commands.last(5).join("\n")
end

def read_history_file(history_file)
  File.readlines(history_file, chomp: true, encoding: "UTF-8")
rescue ArgumentError
  # Fallback for encoding issues
  File.readlines(history_file, chomp: true).select { |line| line.valid_encoding? }
end

def detect_history_file
  # First try HISTFILE environment variable (set by zsh and modern bash)
  return ENV["HISTFILE"] if ENV["HISTFILE"] && File.exist?(ENV["HISTFILE"])

  # Try common zsh history locations
  zsh_history = File.expand_path("~/.zsh_history")
  return zsh_history if File.exist?(zsh_history)

  # Fallback to bash history
  bash_history = File.expand_path("~/.bash_history")
  return bash_history if File.exist?(bash_history)

  nil
end

def extract_commands_from_history(lines, history_file)
  if history_file.include?("zsh_history")
    # Zsh history format: : timestamp:duration;command
    lines.map { |line|
      next "" unless line.valid_encoding?
      line.sub(/^: \d+:\d+;/, "")
    }.reject(&:empty?)
  else
    # Bash history format: plain commands
    lines.select { |line| line.valid_encoding? }
  end
end

def execute_commits(commits)
  commits.each { |commit| execute_single_commit(commit) }
end

def execute_single_commit(commit)
  files = extract_commit_files(commit)
  return if files.empty?

  run_git_add(files)

  commit_msg = commit["message"].to_s.strip
  return if commit_msg.empty?

  run_git_commit(commit_msg)
end

def extract_commit_files(commit)
  Array(commit["files"]).map(&:to_s).reject(&:empty?)
end

def run_git_add(files)
  existing = files.select { |f| File.exist?(f) }
  deleted = files.reject { |f| File.exist?(f) }
  run_git_add_existing(existing)
  run_git_add_deleted(deleted)
end

def run_git_add_existing(paths)
  return if paths.empty?

  add_cmd = ["git", "add", *paths].map { |p| Shellwords.escape(p) }.join(" ")
  puts "Running: #{add_cmd}".green
  abort_staging unless system(add_cmd)
end

def resolve_deleted_paths_for_index(paths)
  index_paths = `git ls-files`.split("\n")
  paths.filter_map do |p|
    next p if index_paths.include?(p)
    next nil unless p.end_with?(".")

    json_path = "#{p.sub(/\.$/, "")}.json"
    index_paths.include?(json_path) ? json_path : nil
  end.uniq
end

def run_git_add_deleted(paths)
  return if paths.empty?

  resolved = resolve_deleted_paths_for_index(paths)
  return if resolved.empty?

  add_u_cmd = ["git", "add", "-u", "--", *resolved].map { |p| Shellwords.escape(p) }.join(" ")
  puts "Running: #{add_u_cmd}".green
  abort_staging unless system(add_u_cmd)
end

def abort_staging
  warn "Staging failed; skipping commit.".red
  exit 1
end

def run_git_commit(message)
  commit_cmd = "git commit -m #{Shellwords.escape(message)}"
  puts "Running: #{commit_cmd}".green
  system(commit_cmd)
end

def current_model_display(debug_mode)
  OpenAiClient.new(debug: debug_mode, progress_title: nil).model
end

def prepare_untracked_files
  all_untracked = `git ls-files --others --exclude-standard`.split("\n").reject(&:empty?)
  return if all_untracked.empty?

  add_cmd = ["git", "add", "-N", *all_untracked].map { |p| Shellwords.escape(p) }.join(" ")
  puts "Running: #{add_cmd}".green
  system("#{add_cmd} 2>/dev/null")
end

def check_for_changes(status_output)
  return true if status_output.lines.count { |line| !line.start_with?("##") }.positive?

  puts "No changes to commit.".yellow
  false
end

def show_git_diff_if_needed(show_diff, recent_commands)
  return unless show_diff
  return if recent_commands.lines.last&.include?("git diff")

  mb = `git merge-base origin/HEAD HEAD 2>/dev/null`.strip
  has_mb = mb != "" && $?.success?
  cmd = has_mb ? "git diff #{Shellwords.escape(mb)} -U50" : "git diff -U50"
  label = has_mb ? "git diff $(git merge-base origin/HEAD HEAD)" : "git diff -U50"
  puts label.cyan
  system(cmd)
  puts
end

def get_mr_diff_output
  out = `git diff origin/HEAD... -U50 2>/dev/null`
  $?.success? ? out : ""
end

def get_uncommitted_diff_output
  out = `git diff -U50`
  unless $?.success?
    warn "Failed to capture uncommitted diff for analysis".red
    exit 1
  end
  out
end

def code_file_excluded?(entry, code_exts)
  path = entry["path"].to_s
  return false if path.empty?

  code_exts.include?(File.extname(path).downcase)
end

def partition_truncation_excluded(excluded, code_exts)
  to_reinclude, kept = excluded.partition { |e| code_file_excluded?(e, code_exts) }
  paths = to_reinclude.map { |e| e["path"].to_s }.reject(&:empty?)
  [kept, paths]
end

def reinclude_excluded_code_files(result)
  excluded = result["excluded_files"] || []
  commits = result["commits"] || []
  return if excluded.empty? || commits.empty?

  code_exts = DiffProcessor::CODE_EXTENSIONS
  kept, paths = partition_truncation_excluded(excluded, code_exts)
  return if paths.empty?

  result["excluded_files"] = kept
  append_paths_to_last_commit(commits, paths)
end

def append_paths_to_last_commit(commits, paths)
  return if paths.empty?

  last = commits.last
  last["files"] = Array(last["files"]) + paths
end

def call_openai_for_plan(debug_mode, status_output, mr_diff_output, uncommitted_diff_output, cli_hint, recent_commits, 
recent_commands)
  client = CommitPlanClient.new(debug: debug_mode)
  client.commit_plan(status_output, mr_diff_output, uncommitted_diff_output, cli_hint, recent_commits, recent_commands)
end

def extract_plan_results(plan, status_output)
  # Guard: API can return nil or non-Hash; assigning result["status_output"] on nil caused NoMethodError.
  return nil unless plan.is_a?(Hash)

  commits = plan["commits"] || []
  return nil if commits.empty?

  warnings = plan["warnings"] || []
  quality_assessment = plan["quality_assessment"]
  excluded_files = plan["excluded_files"] || []
  status_filenames = extract_porcelain_filenames(status_output)
  commits = CommitPathCorrections.apply_to_commits(commits, status_filenames)

  {
    "commits" => commits,
    "warnings" => warnings,
    "quality_assessment" => quality_assessment,
    "excluded_files" => excluded_files
  }
end

def plan_commits(debug_mode, cli_hint, recent_commits, recent_commands, show_diff: false)
  status_output = run_cmd("git status --porcelain --branch")
  return nil unless check_for_changes(status_output)

  prepare_untracked_files
  show_git_diff_if_needed(show_diff, recent_commands)
  mr_diff_output = get_mr_diff_output
  uncommitted_diff_output = get_uncommitted_diff_output
  plan = call_openai_for_plan(debug_mode, status_output, mr_diff_output, uncommitted_diff_output, cli_hint, 
recent_commits, recent_commands)
  result = extract_plan_results(plan, status_output)
  return nil if result.nil?

  reinclude_excluded_code_files(result)
  result["status_output"] = status_output
  result
end

def watch_loop(debug_mode, cli_hint, recent_commits, last_status)
  loop do
    sleep WATCH_INTERVAL
    new_status = run_cmd("git status --porcelain --branch")
    next if new_status == last_status

    plan_result = plan_commits(debug_mode, cli_hint, recent_commits, get_recent_commands, show_diff: false)
    last_status = plan_result ? plan_result["status_output"] : new_status
    next if plan_result.nil?

    CompletionNotifier.notify_completion(success: true, title: "✓ Commit Planning Done")
    GitCommitDisplay.display_commits_result(
      plan_result["commits"],
      plan_result["warnings"],
      plan_result["quality_assessment"],
      plan_result["excluded_files"]
    )
    puts "Watching for file changes (every #{WATCH_INTERVAL}s). Ctrl+C to exit.".yellow
  end
end

# Entry point
CompletionNotifier.setup_exit_hook

debug_mode, cli_hint, watch_mode = parse_arguments(ARGV)

# Change to git root directory to ensure consistent path handling
git_root = get_git_root
Dir.chdir(git_root)

puts "Model: #{current_model_display(debug_mode)}".cyan

recent_commits = `git log -15 --pretty=%s 2>/dev/null`.strip
recent_commands = get_recent_commands

loop do
  plan_result = plan_commits(debug_mode, cli_hint, recent_commits, recent_commands, show_diff: true)
  break if plan_result.nil?

  commits = plan_result["commits"]
  warnings = plan_result["warnings"]
  quality_assessment = plan_result["quality_assessment"]
  excluded_files = plan_result["excluded_files"]

  warnings_fixed = GitCommitRubocop.handle_rubocop_warnings

  if warnings_fixed
    puts "\nFiles have changed after fixing warnings. Re-planning commits...".cyan
    recent_commands = get_recent_commands
    next
  end

  CompletionNotifier.notify_completion(success: true, title: "✓ Commit Planning Done")
  if watch_mode
    GitCommitDisplay.display_commits_result(commits, warnings, quality_assessment, excluded_files)
    puts "Watching for file changes (every #{WATCH_INTERVAL}s). Ctrl+C to exit.".yellow
    watch_loop(debug_mode, cli_hint, recent_commits, plan_result["status_output"])
  else
    GitCommitDisplay.display_commits_and_ask(commits, warnings, quality_assessment, excluded_files)
    execute_commits(commits)
  end
  break
end

exit 0 if watch_mode

# Check if there's a remote before asking to push
remote_output = `git remote 2>/dev/null`.strip
has_remote = !remote_output.empty?

if has_remote
  puts "Do you want to push? (y/N)".white
  push_answer = PromptReader.read_line("", downcase: true)

  if push_answer == "y"
    puts "Running: git push".green
    success = system("git push")
    exit(success ? 0 : 1)
  else
    puts "Changes committed but not pushed.".yellow
    exit 0
  end
else
  puts "Changes committed. No remote configured to push to.".yellow
  exit 0
end
