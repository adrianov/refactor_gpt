#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/openai_client"
require_relative "lib/agents_file_handler"
require "shellwords"
require "colorize"
require "reline"

class GitExplainer
  include AgentsFileHandler

  def initialize(model: nil, debug: false)
    @client = OpenAiClient.new(model: model, debug: debug,
      progress_title: "Analyzing changes")
  end

  def ask(prompts)
    @client.ask(prompts)
  end

  def explain_changes(status_output, diff_output, recent_commits, recent_commands)
    ask([
      {role: "system", content: system_instruction},
      {role: "user", content: build_user_content(status_output, diff_output, recent_commits, recent_commands)}
    ])
  end

  private

  def build_user_content(status_output, diff_output, recent_commits, recent_commands)
    content_parts = []

    content_parts.concat([
      "Here is the git status:\n#{status_output.strip}\n\n",
      "Here is the git diff for all changes:\n#{diff_output.strip}\n\n",
      "Here are the last 15 git commit one-line messages (most recent first):\n#{recent_commits.strip}\n\n"
    ])

    unless recent_commands.empty?
      content_parts << <<~HEREDOC
        Here are the last 5 shell commands from the user's terminal history (most recent last):

        #{recent_commands}
      HEREDOC
    end

    content_parts.join("\n")
  end

  def system_instruction
    agents_content = load_agents_file
    has_agents = !agents_content.empty?

    instruction_parts = []

    instruction_parts << <<~HEREDOC
      You are a tool that analyzes git changes and creates comprehensive explanations in Markdown format.

      Input:
      - `git status` output (shows current branch name, added, modified, deleted, renamed, untracked files)
      - unified git diff for all changes (including new files)
      - last 15 git commit one-line messages to understand project context
      - last 5 shell commands from the user's terminal history for additional context
    HEREDOC

    instruction_parts << "- Ruby development guidelines from AGENTS.md\n" if has_agents

    instruction_parts << <<~HEREDOC

      Task:
      Analyze the changes and create a technical developer-focused Markdown explanation with these sections:

      # [Clear, descriptive title summarizing the main changes]

      ## 1. The Goal
      - Primary technical purpose and objectives of these changes
      - What problem or requirement this addresses
      - Expected outcomes and benefits

      ## 2. Use Cases
      - Specific scenarios where these changes will be applied
      - User workflows or developer interactions enabled
      - Integration points with existing functionality
      - Edge cases and special conditions handled

      ## 3. Developer Journey
      - **Problem Understanding**: How the core issue or requirement was identified
      - **Initial Approach**: First ideas and why they worked or didn't work
      - **Iterative Refinement**: Step-by-step evolution of the solution with code examples
        - **Example Data Structures**: Illustrate the journey with concrete examples of:
          - Models/Entities being modified (e.g., User, Product, Order objects with actual data)
          - API request/response payloads showing before/after states
          - Database schema changes with sample records
          - Configuration structures and their transformations
      - **Key Decisions**: Critical technical choices and their rationale
      - **Implementation Details**: Specific code patterns and techniques used
      - **Testing Strategy**: How the solution was verified to work correctly
      - **Lessons Learned**: What was discovered during the development process

      ## 4. Technical Implementation
      - **Code Changes**: Detailed analysis of each modified file with specific line numbers
      - **API Changes**: New methods, modified signatures, breaking changes
      - **Dependencies**: New gems, imports, or external dependencies
      - **Before/After Comparisons**: Show specific code changes with explanations
      - **Logic Flow**: How execution flow is affected
      - **Performance Implications**: Any performance considerations
      - **Error Handling**: Changes to exception handling, validation

      ## 5. Testing Recommendations
      - Analyze the current project structure and existing test patterns
      - Determine appropriate testing framework (Minitest vs RSpec) based on Ruby conventions
      - Identify which components need unit tests vs integration tests vs end-to-end tests
      - Consider testing approach for git operations, API interactions, and display functionality
      - Recommend specific test tools for mocking external dependencies (HTTP, git commands)
      - Suggest test organization structure that fits the current codebase layout

      ## 6. Key Takeaways
      - Most important technical points developers need to remember (3-7 bullet points)
      - Critical changes that affect daily work
      - Essential actions or considerations
      - Migration path for existing code
      - Common pitfalls or things to watch out for

      Format Requirements:
      - Use proper Markdown with code blocks showing actual diff content
      - Include specific file paths and line numbers (e.g., `src/models/user.rb:45-52`)
      - Show actual code snippets with syntax highlighting
      - Focus on technical implementation details, not business value
      - Be specific about what developers need to know to work with this code
      - Include practical examples and usage patterns
      - **IMPORTANT**: Only include sections that have meaningful content. Skip sections with "None", "No changes", "Not applicable", or similar empty responses. Keep the report focused and easy to read.
    HEREDOC

    if has_agents
      instruction_parts << <<~HEREDOC

        AGENTS.md content (development guidelines to consider):
        #{agents_content}
      HEREDOC
    end

    instruction_parts.join
  end
end

def run_interactive_questions(initial_explanation, debug_mode)
  display_interactive_prompt
  explainer = GitExplainer.new(debug: debug_mode)
  messages = initialize_conversation_messages(initial_explanation)

  loop do
    question = get_user_question
    break unless question

    process_user_question(explainer, messages, question)
  end
end

def display_interactive_prompt
  puts "\n💬 Ask follow-up questions about the changes (Ctrl+D to exit):"
  puts "   • Type your questions about specific files, implementation details, or suggestions"
  puts "   • Press Enter twice to submit your question\n"
end

def initialize_conversation_messages(initial_explanation)
  [
    {role: "system", content: build_followup_system_instruction},
    {role: "assistant", content: initial_explanation}
  ]
end

def get_user_question
  lines = []

  loop do
    line = Reline.readline(lines.empty? ? "? " : "  ", true)
    return nil if line.nil?

    line = line.strip
    if line.empty?
      break unless lines.empty?
      return nil
    end

    lines << line
  end

  lines.join("\n")
end

def process_user_question(explainer, messages, question)
  messages << {role: "user", content: question}

  answer = explainer.ask(messages)
  messages << {role: "assistant", content: answer}

  display_with_glow(answer)
  puts "\n"
end

def build_followup_system_instruction
  <<~HEREDOC
    You are helping a developer understand git changes through a Q&A session. The user has already received a comprehensive initial analysis with detailed structure. Now they want focused follow-up answers.

    CRITICAL: For follow-up questions, provide SHORT, FOCUSED responses. The big detailed structure was for the initial analysis only.

    Your role for follow-ups:
    - Answer specific questions directly and concisely
    - Clarify points from the initial analysis
    - Provide targeted code examples when needed
    - Suggest specific improvements for particular concerns

    Response format for follow-ups:
    - 1-3 paragraphs maximum for complex topics
    - 1-2 sentences for simple questions
    - Use bullet points only when listing multiple distinct items
    - Avoid repeating the comprehensive structure from initial analysis
    - Focus only on what the user specifically asked

    Examples:
    Q: "Why was this method extracted?"
    A: "The method was extracted to reduce complexity and improve testability. It now has a single responsibility for processing user input, making the code more maintainable."

    Q: "What about error handling?"
    A: "The extracted method includes input validation and raises ArgumentError for invalid data. Error cases are handled at the boundary rather than scattered throughout the original method."

    Guidelines:
    - Be direct and to the point
    - Reference specific files/lines when relevant
    - Provide minimal but sufficient code examples
    - Focus on the specific question asked
  HEREDOC
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

  args.each do |arg|
    case arg
    when "--debug" then debug_mode = true
    end
  end

  debug_mode
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
  begin
    File.readlines(history_file, chomp: true, encoding: "UTF-8")
  rescue ArgumentError
    # Fallback for encoding issues
    File.readlines(history_file, chomp: true).select { |line| line.valid_encoding? }
  end
end

def detect_history_file
  # First try HISTFILE environment variable (set by zsh and modern bash)
  return ENV["HISTFILE"] if ENV["HISTFILE"] && File.exist?(ENV["HISTFILE"])

  # Try common zsh history location
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

def display_with_glow(content)
  return puts content unless glow_available?

  width = calculate_glow_width(content)
  formatted = format_content_for_glow(content)
  display_with_glow_process(formatted, width)
end

def glow_available?
  system("command -v glow >/dev/null 2>&1")
end

def calculate_glow_width(content)
  urls = content.scan(%r{\[.*?\]\(https?://[^)]+\)|https?://[^\s)]+})
  urls.empty? ? "100" : [urls.map(&:length).max + 2, 100].max.to_s
end

def format_content_for_glow(content)
  content.gsub(%r{\(\s*\n\s*(https?://[^)]+)\)}, '(\\1)')
    .gsub(%r{(\[.*?\]\(https?://[^)]+\))}, "\n\n\\1")
end

def display_with_glow_process(formatted, width)
  IO.popen(ENV.to_h.merge({"CLICOLOR_FORCE" => "1"}),
    ["glow", "--width", width, "--style", "dark", "-"], "w+") do |io|
    io.write(formatted)
    io.close_write

    io.each_line { |line| puts clean_glow_line(line) }
  end
end

def clean_glow_line(line)
  line.gsub(/(\e\[[\d;]+m\s*)+$/, "\e[0m")
    .sub(/^.*?  /, "")
end

# Entry point
debug_mode = parse_arguments(ARGV)

status_output = run_cmd("git status")

if status_output.strip.empty? ||
    status_output.include?("nothing to commit") ||
    status_output.include?("working tree clean")
  puts "No changes to explain.".yellow
  exit 0
end

recent_commits = `git log -15 --pretty=%s 2>/dev/null`.strip
recent_commands = get_recent_commands

# Get all untracked files and filter out excluded ones before adding to tracking
all_untracked = `git ls-files --others`.split("\n")
excluded_files = `git ls-files --others --exclude-standard`.split("\n")

# Additional patterns to exclude from git add -N (temporary, binary, debug files)
additional_exclusions = [
  "*.log", "*.tmp", "*.temp", "*.bak", "*.swp", "*.swo",
  "*.pyc", "*.pyo", "*.class", "*.jar", "*.war", "*.ear",
  "*.zip", "*.tar.gz", "*.tgz", "*.rar", "*.exe", "*.dll",
  "*.so", "*.dylib", "*.bin", "*.dat", "*.orig", "*.rej",
  ".DS_Store", "Thumbs.db"
]

# Filter out files matching exclusion patterns
files_to_add = all_untracked.reject do |file|
  excluded_files.include?(file) ||
    additional_exclusions.any? { |pattern| File.fnmatch(pattern, File.basename(file)) }
end

unless files_to_add.empty?
  add_cmd = ["git", "add", "-N", *files_to_add].map { |p| Shellwords.escape(p) }.join(" ")
  system("#{add_cmd} 2>/dev/null")
end

# Capture diff output for analysis with 500 lines context
diff_output = `git diff -U500`
unless $?.success?
  warn "Failed to capture diff for analysis".red
  exit 1
end

explanation = GitExplainer.new(debug: debug_mode).explain_changes(
  status_output,
  diff_output,
  recent_commits,
  recent_commands
)

display_with_glow(explanation)
run_interactive_questions(explanation, debug_mode) if $stdin.tty?
