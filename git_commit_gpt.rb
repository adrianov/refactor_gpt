#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/openai_client'
require_relative 'lib/agents_file_handler'
require 'shellwords'
require 'ruby-progressbar'
require 'colorize'

class OpenAi
  include AgentsFileHandler

  def initialize(model: nil, debug: false)
    @client = OpenAiClient.new(model: model, debug: debug, progress_title: 'Planning commits'.cyan)
  end

  def ask(prompts)
    @client.ask(prompts)
  end

  def commit_plan(status_output, diff_output, cli_hint, recent_commits, recent_commands)
    user_content = build_user_content(status_output, diff_output, cli_hint, recent_commits, recent_commands)
    raw_response = ask([
                         { role: 'system', content: system_instruction },
                         { role: 'user', content: user_content }
                       ])
    parse_commit_plan_response(raw_response)
  end

  private

  def build_user_content(status_output, diff_output, cli_hint, recent_commits, recent_commands)
    content_parts = []

    content_parts << <<~HEREDOC unless cli_hint.empty?
      Here are hints or preferences from the user:

      #{cli_hint}
    HEREDOC

    content_parts.concat([
                           <<~HEREDOC
                               Here is the git status:

                               #{status_output}
                             HEREDOC,
                             <<~HEREDOC
                               Here is the git diff for all changes:

                               #{diff_output}
                             HEREDOC,
                             <<~HEREDOC
                               Here are the last 5 git commit one-line messages (most recent first):

                               #{recent_commits}
                           HEREDOC
                         ])

    unless recent_commands.empty?
      content_parts << <<~HEREDOC
        Here are the last 5 shell commands from the user's terminal history (most recent last):

        #{recent_commands}
      HEREDOC
    end

    content_parts.join("\n")
  end

  def parse_commit_plan_response(raw_response)
    json_str = raw_response.gsub(/^```.*\n?/, '').gsub(/```$/, '').strip
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
      - last 5 git commit one-line messages to help you match existing style
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
      - Additionally, carefully review the provided diffs for potential errors or issues (such as obvious bugs, suspicious logic, or likely regressions)#{has_agents ? ' based on the development guidelines provided in AGENTS.md' : ''}.
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

# Parse arguments for debug mode
debug_mode = false
cli_hint_parts = []

ARGV.each do |arg|
  case arg
  when '--debug' then debug_mode = true
                      next
  end
  cli_hint_parts << arg
end

cli_hint = cli_hint_parts.join(' ').to_s.strip

status_output = run_cmd('git status')

if status_output.strip.empty? || status_output.include?('nothing to commit') || status_output.include?('working tree clean')
  puts 'No changes to commit.'.yellow
  exit 0
end

recent_commits = run_cmd('git log -5 --pretty=%s')
recent_commands = begin
  history_file = ENV['HISTFILE'] || File.expand_path('~/.bash_history')
  if File.exist?(history_file)
    lines = File.readlines(history_file, chomp: true)
    lines.last(5).join("\n")
  else
    ''
  end
end

# Check if last command was git diff to avoid showing it twice
last_command_was_git_diff = recent_commands.lines.last&.include?('git diff')

unless last_command_was_git_diff
  system('git diff')
  puts
end

# Capture diff output for OpenAI analysis
diff_output = `git diff`
unless $?.success?
  warn 'Failed to capture diff for analysis'.red
  exit 1
end

plan = OpenAi.new(debug: debug_mode).commit_plan(
  status_output,
  diff_output,
  cli_hint,
  recent_commits,
  recent_commands
)
commits = plan['commits'] || []
warnings = plan['warnings'] || []

if commits.empty?
  puts 'No commits suggested by the model.'.yellow
  exit 0
end

unless warnings.empty?
  puts 'Warnings:'.yellow
  warnings.each do |warning|
    file = warning['file'].to_s
    description = warning['description'].to_s
    probability = warning['probability']
    probability_str = probability.nil? ? 'n/a' : probability.to_s
    puts "Warning in #{file}: #{description} (probability: #{probability_str})".yellow
  end
  puts
end

puts
puts 'Planned commits:'.cyan
commits.each_with_index do |commit, idx|
  puts "Commit ##{idx + 1}: #{commit['message']}".cyan
  Array(commit['files']).each do |file|
    puts "  - #{file}".blue
  end
  puts
end

puts 'Do you want to run these git add/commit commands? (y/N)'.white
answer = STDIN.gets.to_s.chomp.downcase

unless answer == 'y'
  puts 'Commands not executed.'.yellow
  exit 0
end

commits.each do |commit|
  files = Array(commit['files']).map(&:to_s).reject(&:empty?)
  next if files.empty?

  add_cmd = ['git', 'add', *files].map { |p| Shellwords.escape(p) }.join(' ')
  puts "Running: #{add_cmd}".green
  system(add_cmd)

  commit_msg = commit['message'].to_s.strip
  next if commit_msg.empty?

  commit_cmd = "git commit -m #{Shellwords.escape(commit_msg)}"
  puts "Running: #{commit_cmd}".green
  system(commit_cmd)
end

puts 'Do you want to push? (y/N)'.white
push_answer = STDIN.gets.to_s.chomp.downcase

if push_answer == 'y'
  puts 'Running: git push'.green
  system('git push')
else
  puts 'Changes committed but not pushed.'.yellow
end
