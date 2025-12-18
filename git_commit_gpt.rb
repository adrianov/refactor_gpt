#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/openai_client"
require_relative "lib/agents_file_handler"
require "shellwords"
require "ruby-progressbar"
require "colorize"

class OpenAi
  include AgentsFileHandler

  def initialize(model: nil, debug: false)
    @client = OpenAiClient.new(model: model, debug: debug,
      progress_title: "Planning commits".cyan)
  end

  def ask(prompts)
    @client.ask(prompts)
  end

  def commit_plan(status_output, diff_output, cli_hint, recent_commits,
    recent_commands)
    raw_response = ask([
      {role: "system", content: system_instruction},
      {role: "user",
       content: build_user_content(status_output, diff_output, cli_hint, recent_commits,
         recent_commands)}
    ])
    parse_commit_plan_response(raw_response)
  end

  private

  def build_user_content(status_output, diff_output, cli_hint, recent_commits,
    recent_commands)
    content_parts = []

    content_parts << "Here are hints or preferences from the user:\n\n#{cli_hint}\n" unless cli_hint.empty?

    content_parts.concat([
      "Here is the git status:\n\n#{status_output}\n",
      "Here is the git diff for all changes:\n\n#{diff_output}\n",
      "Here are the last 15 git commit one-line messages (most recent first):\n\n#{recent_commits}\n"
    ])

    unless recent_commands.empty?
      content_parts << "Here are the last 5 shell commands from the user's terminal history " \
        "(most recent last):\n\n#{recent_commands}\n"
    end

    content_parts.join("\n")
  end

  def parse_commit_plan_response(raw_response)
    json_str = raw_response.gsub(/^```.*\n?/, "").gsub(/```$/, "").strip
    Oj.load(json_str)
  rescue Oj::ParseError
    puts "Failed to parse model response as JSON. Raw response:\n#{raw_response}".red
    exit 1
  end

  def system_instruction
    agents_content = load_agents_file
    has_agents = !agents_content.empty?

    instruction_parts = []

    instruction_parts << <<~HEREDOC
      You are a tool that groups changed files into meaningful git commits.

      Input:
      - `git status` output (shows current branch name, added, modified, deleted, renamed, untracked files)
      - unified git diff for all changes (including new files)
      - optional user-provided hints or preferences from the command line
      - last 15 git commit one-line messages to help you match existing style
      - last 5 shell commands from the user's terminal history to give you extra context
    HEREDOC

    instruction_parts << "- Ruby development guidelines from AGENTS.md\n" if has_agents

    instruction_parts << <<~HEREDOC

      Task:
      - Analyze the status and diff and infer logical groups of changes (by feature, bugfix, refactor, docs, tests, etc.).
      - **Language Detection**: Analyze recent commit messages to determine the primary language. Use the same language for new commits to maintain consistency. Default to English if no recent commits exist.
      - Prefer commit messages that are consistent with the style and language of the provided recent commit messages.
      - Respect and incorporate user-provided hints when choosing commit messages, grouping files, or prioritizing certain changes, as long as this does not conflict with the actual diffs.
      - Check the current branch name (available in git status output) and recent commit messages for JIRA task references (patterns like PT-4668, ABC-123, etc.).
      - If a JIRA task reference is found in the branch name or recent commits, use the same reference format at the beginning of commit messages (e.g., "[PT-4668] type: short description").
      - For each group, produce:
        - a one-line, conventional-style commit message (no trailing period) that describes the specific atomic change,
        - **Language principles**:
          - **English**: Use imperative verbs - "add X", "fix Y", "remove Z"
          - **Russian**: Use verbal nouns - "добавление X", "исправление Y", "удаление Z"
          - **Other languages**: Follow standard commit message conventions for that language
        - **Universal principles**:
          - Be specific about what changed and why
          - Avoid vague terms like "optimization", "improvement", "fix issues"
          - Focus on concrete actions and outcomes
        - a list of file paths to include in that commit.
      - Every changed file from the status output must appear in exactly one group.
      - Use only relative file paths exactly as they appear in the status output (after the status flags).
      - Prefer a small number of coherent commits over many tiny ones.
       - Additionally, carefully review the provided diffs for potential errors or issues (such as obvious bugs, suspicious logic, or likely regressions)#{has_agents ? " based on the development guidelines provided in AGENTS.md" : ""}.
       - **Special attention to unused code and reference errors**: Pay special attention to detecting:
         - Unused methods that were left behind after refactoring
         - Unused variables or constants that are no longer referenced
         - Calls to undefined methods, functions, or variables
         - References to deleted or moved code elements
         - Dead code that serves no purpose
       - If you detect any potential error in a file or diff hunk, include a warning entry describing:
         - the affected file path,
         - a short description of the possible error,
         - a probability (0.0–1.0) indicating how sure you are that this is a real issue.
    HEREDOC

    if has_agents
      instruction_parts << <<~HEREDOC

        AGENTS.md content (development guidelines to follow):
        #{agents_content}
      HEREDOC
    end

    instruction_parts << <<~HEREDOC

      Output format (strict JSON):
      {
        "commits": [
          {
            "message": "type: short description",
            "files": ["path/one.rb", "path/two.rb"]
          }
        ],
        "warnings": [
          {
            "file": "path/one.rb",
            "description": "Possible off-by-one error in loop bounds",
            "probability": 0.8
          }
        ]
      }

      If you do not see any likely errors, return "warnings": [].

      Do not include any text outside of the JSON.
    HEREDOC

    instruction_parts.join
  end
end

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

# Main execution
def parse_arguments(args)
  debug_mode = false
  cli_hint_parts = []

  args.each do |arg|
    case arg
    when "--debug" then debug_mode = true
                        next
    end
    cli_hint_parts << arg
  end

  [debug_mode, cli_hint_parts.join(" ").to_s.strip]
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

  add_files_to_index(files)
  commit_files(commit["message"])
end

def extract_commit_files(commit)
  Array(commit["files"]).map(&:to_s).reject(&:empty?)
end

def add_files_to_index(files)
  add_cmd = ["git", "add", *files].map { |p| Shellwords.escape(p) }.join(" ")
  puts "Running: #{add_cmd}".green
  system(add_cmd)
end

def commit_files(commit_message)
  commit_msg = commit_message.to_s.strip
  return if commit_msg.empty?

  commit_cmd = "git commit -m #{Shellwords.escape(commit_msg)}"
  puts "Running: #{commit_cmd}".green
  system(commit_cmd)
end

def display_commits_and_ask(commits, warnings)
  display_warnings(warnings)
  display_planned_commits(commits)
  get_user_confirmation
end

def get_file_stats(files)
  return {} unless files.any?

  # Get diff stats for the specific files
  stat_cmd = "git diff --stat -- #{files.map { |f| Shellwords.escape(f) }.join(" ")}"
  stat_output = `#{stat_cmd} 2>/dev/null`

  return {} unless $?.success?

  parse_stats_output(stat_output, files)
end

def parse_stats_output(output, files)
  stats = {}

  output.lines.each { |line| process_stat_line(line, stats) }
  ensure_all_files_have_stats(files, stats)
  stats
end

def process_stat_line(line, stats)
  return if summary_line?(line)

  match = line.match(/^\s*(.+?)\s+\|\s*(\d+)\s*([+-]+)?\s*$/)
  return unless match

  filename = match[1].strip
  total_changes = match[2].to_i
  plus_minus = match[3] || ""

  return unless total_changes > 0

  additions = plus_minus.count("+")
  deletions = plus_minus.count("-")
  stats[filename] = "#{additions}+#{deletions}-"
end

def summary_line?(line)
  line.include?("changed") || line.include?("insertion") || line.include?("deletion")
end

def ensure_all_files_have_stats(files, stats)
  files.each { |file| stats[file] ||= "" }
end

def display_warnings(warnings)
  return if warnings.empty?

  puts "Warnings:".yellow
  warnings.each { |warning| display_single_warning(warning) }
  puts
end

def display_single_warning(warning)
  file = warning["file"].to_s
  description = warning["description"].to_s
  probability = warning["probability"]
  probability_str = probability.nil? ? "n/a" : probability.to_s
  puts "Warning in #{file}: #{description} (probability: #{probability_str})".yellow
end

def display_planned_commits(commits)
  puts
  puts "Planned commits:".cyan
  commits.each_with_index { |commit, idx| display_single_commit(commit, idx) }
end

def display_single_commit(commit, idx)
  puts "Commit ##{idx + 1}: #{commit["message"]}".cyan
  files = Array(commit["files"])

  return puts unless files.any?

  file_stats = get_file_stats(files)
  max_filename_length = files.map(&:length).max

  # Display total statistics for the commit
  display_commit_total_stats(file_stats, files)

  files.each { |file| display_file_with_stats(file, file_stats, max_filename_length) }
  puts
end

def display_file_with_stats(file, file_stats, max_filename_length)
  stat_info = file_stats[file] || ""
  padding = " " * (max_filename_length - file.length)

  print "  - #{file}#{padding}".blue
  print " " unless stat_info.empty?

  if stat_info.empty?
    puts
  else
    puts format_colored_stats(stat_info)
  end
end

def format_colored_stats(stat_info)
  additions, deletions = stat_info.match(/(\d+)\+(\d+)-/)&.captures
  return "" unless additions && deletions

  "[".white + "+#{additions}".green + " ".white + "-#{deletions}".red + "]".white
end

def display_commit_total_stats(file_stats, files)
  total_additions = 0
  total_deletions = 0

  file_stats.each_value do |stat|
    additions, deletions = stat.match(/(\d+)\+(\d+)-/)&.captures
    next unless additions && deletions

    total_additions += additions.to_i
    total_deletions += deletions.to_i
  end

  total_changes = total_additions + total_deletions
  puts "  Total: #{total_changes} changes (#{total_additions} additions, #{total_deletions} deletions)".yellow
end

def get_user_confirmation
  puts "Do you want to run these git add/commit commands? (y/N)".white
  answer = $stdin.gets.to_s.chomp.downcase

  unless answer == "y"
    puts "Commands not executed.".yellow
    exit 0
  end
end

# Entry point
debug_mode, cli_hint = parse_arguments(ARGV)

status_output = run_cmd("git status")

if status_output.strip.empty? ||
    status_output.include?("nothing to commit") ||
    status_output.include?("working tree clean")
  puts "No changes to commit.".yellow
  exit 0
end

recent_commits = `git log -15 --pretty=%s 2>/dev/null`.strip
recent_commands = get_recent_commands

# Get all untracked files and filter out ignored ones before adding to tracking
# git ls-files --others --exclude-standard already respects .gitignore and other standard exclusions
all_untracked = `git ls-files --others --exclude-standard`.split("\n")

# Additional patterns to exclude from git add -N (temporary, binary, debug files)
additional_exclusions = [
  "*.log", "*.tmp", "*.temp", "*.bak", "*.swp", "*.swo",
  "*.pyc", "*.pyo", "*.class", "*.jar", "*.war", "*.ear",
  "*.zip", "*.tar.gz", "*.tgz", "*.rar", "*.exe", "*.dll",
  "*.so", "*.dylib", "*.bin", "*.dat", "*.orig", "*.rej",
  ".DS_Store", "Thumbs.db"
]

# Filter out files matching additional exclusion patterns
files_to_add = all_untracked.reject do |file|
  additional_exclusions.any? { |pattern| File.fnmatch(pattern, File.basename(file)) }
end

unless files_to_add.empty?
  add_cmd = ["git", "add", "-N", *files_to_add].map { |p| Shellwords.escape(p) }.join(" ")
  puts "Running: #{add_cmd}".green
  system("#{add_cmd} 2>/dev/null")
end

# Show all changes in git diff (no exclusions) unless last command was git diff
unless recent_commands.lines.last&.include?("git diff")
  system("git diff")
  puts
end

# Capture diff output for OpenAI analysis with 500 lines context
diff_cmd = "git diff -U500"
diff_output = `#{diff_cmd}`
unless $?.success?
  warn "Failed to capture diff for analysis".red
  exit 1
end

plan = OpenAi.new(debug: debug_mode).commit_plan(
  status_output,
  diff_output,
  cli_hint,
  recent_commits,
  recent_commands
)
commits = plan["commits"] || []
warnings = plan["warnings"] || []

if commits.empty?
  puts "No commits suggested by the model.".yellow
  exit 0
end

display_commits_and_ask(commits, warnings)
execute_commits(commits)

# Check if there's a remote before asking to push
remote_output = `git remote 2>/dev/null`.strip
has_remote = !remote_output.empty?

if has_remote
  puts "Do you want to push? (y/N)".white
  push_answer = $stdin.gets.to_s.chomp.downcase

  if push_answer == "y"
    puts "Running: git push".green
    system("git push")
  else
    puts "Changes committed but not pushed.".yellow
  end
else
  puts "Changes committed. No remote configured to push to.".yellow
end
