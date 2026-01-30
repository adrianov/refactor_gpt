#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/signal_handler"
require_relative "lib/openai_client"
require_relative "lib/gemini_client"
require_relative "lib/agents_file_handler"
require_relative "lib/completion_notifier"
require "shellwords"
require "colorize"

PROJECT_ROOT = Dir.pwd.freeze

class Verify
  include AgentsFileHandler

  def initialize(model: nil, debug: false, project_root: PROJECT_ROOT)
    @model = model
    @debug = debug
    @project_root = project_root
  end

  def ask(prompts)
    client = OpenAiClient.new(model: @model, debug: @debug,
      progress_title: nil, raise_on_server_error: true)
    client.ask(prompts)
  rescue ServerError => e
    handle_gemini_fallback(prompts, e)
  end


  def assess_feature(user_request, status_output, diff_output)
    prompts = [
      {role: "system", content: system_instruction},
      {role: "user", content: build_user_content(user_request, status_output, diff_output)}
    ]
    print_full_prompt(prompts) if @debug
    ask(prompts)
  end

  private

  def print_full_prompt(prompts)
    warn '--- Full prompt ---'.light_black
    prompts.each do |msg|
      warn "[#{msg[:role].upcase}]".light_black
      warn msg[:content]
      warn ''
    end
    warn '--- End full prompt ---'.light_black
  end

  def handle_gemini_fallback(prompts, error)
    return handle_final_error(error) unless gemini_configured?

    warn "⚠️  Server error persisted after 3 retries, falling back to Gemini..."
    gemini_client = GeminiClient.new(model: @model, debug: @debug, progress_title: nil)
    gemini_client.ask(prompts)
  end

  def handle_final_error(_error)
    warn "❌ Server error persisted after 3 retries and Gemini is not available"
    exit 1
  end

  def gemini_configured?
    env_vars = load_env_vars(@project_root)
    env_vars.key?("GEMINI_ACCESS_TOKEN") && !env_vars["GEMINI_ACCESS_TOKEN"].empty?
  end

  def build_user_content(user_request, status_output, diff_output)
    content_parts = [
      "User request: #{user_request}\n\n",
      "Here is the git status:\n#{status_output.strip}\n\n"
    ]

    unless diff_output.strip.empty?
      content_parts << "Here is the git diff for all changes:\n#{diff_output.strip}\n"
    end

    content_parts.join("\n")
  end

  def system_instruction
    <<~HEREDOC
      You are a tool that verifies whether code changes fully implement a requested feature.

      Task:
      Verify that the code changes fully implement the user's request without introducing bugs or regressions.

      Available information:
      - Current user request
      - Final summary/response from the previous agent run that attempted to implement the feature

      Verification approach:
      - Review the previous agent's response to understand what was implemented
      - You may check git diff (using 'git diff') or read relevant files to verify the changes
      - Check if the changes address the user's request
      - Look for potential bugs, regressions, or missing functionality
      - Verify code quality and adherence to project guidelines

      Response format:
      - Start your response with "YES: " followed by a brief description if verification passes
      - Start your response with "NO: " followed by a brief description if verification fails

      CRITICAL requirements:
      - Your response MUST start with either "YES" or "NO" as the first word
      - Use minimal formatting only - avoid excessive markdown or formatting
      - Keep your response short and concise - one sentence is sufficient
      - The description after YES/NO should be brief and specific
      - DO NOT use thinking blocks or any other output format. Just the YES/NO response.
    HEREDOC
  end
end

def run_cmd(cmd, capture_output: true, project_root: PROJECT_ROOT)
  git_cmd = cmd.start_with?("git ") ? "git -C #{Shellwords.escape(project_root)} #{cmd[4..-1]}" : cmd
  if capture_output
    output = `#{git_cmd}`
    unless $?.success?
      puts "NO: Command failed: #{git_cmd}"
      exit 1
    end
    output
  else
    system(git_cmd)
    unless $?.success?
      puts "NO: Command failed: #{git_cmd}"
      exit 1
    end
  end
end

def parse_arguments(args)
  debug_mode = args.include?("--debug")
  feature_request_parts = args.reject { |arg| arg == "--debug" }

  [debug_mode, feature_request_parts.join(" ").to_s.strip]
end

def read_feature_request_from_stdin
  $stdin.read.strip unless $stdin.tty?
end

def get_feature_request(args)
  feature_request = args.reject { |arg| arg == "--debug" }.join(" ").strip
  return feature_request unless feature_request.empty?

  stdin_request = read_feature_request_from_stdin
  return stdin_request if stdin_request && !stdin_request.empty?

  exit 0
end

def parse_response(response)
  return [false, response] if response.nil? || response.strip.empty?

  normalized = response.strip
  upcased = normalized.upcase

  return parse_yes_response(normalized) if upcased.start_with?("YES")
  return parse_no_response(normalized) if upcased.start_with?("NO")

  yes_match = upcased.match(/\bYES\s*:?/i)
  no_match = upcased.match(/\bNO\s*:?/i)

  return parse_no_response(normalized) if no_match && (yes_match.nil? || no_match.begin(0) < yes_match.begin(0))
  return parse_yes_response(normalized) if yes_match && (no_match.nil? || yes_match.begin(0) < no_match.begin(0))

  [false, response]
end

def parse_no_response(normalized)
  match = normalized.match(/\bNO\s*:?\s*(.*)/im)
  description = match ? match[1].strip : ""
  [false, description.empty? ? "Verification failed" : description]
end

def parse_yes_response(normalized)
  match = normalized.match(/\bYES\s*:?\s*(.*)/im)
  description = match ? match[1].strip : ""
  [true, description.empty? ? "Verification passed" : description]
end

def display_result(verified, description)
  if verified
    puts "YES: #{description}"
    exit 0
  else
    puts "NO: Unable to parse assessment response. The LLM response did not contain YES or NO."
    if description && !description.strip.empty?
      puts "\nActual LLM response:"
      # Use multiline output for the actual response to ensure it's fully visible
      description.each_line { |line| puts line.chomp }
      puts "\nFull response length: #{description.length} characters"
    end
    exit 1
  end
end

def prepare_untracked_files(project_root: PROJECT_ROOT)
  all_untracked = `git -C #{Shellwords.escape(project_root)} ls-files --others --exclude-standard`.split("\n")
  unless $?.success?
    puts "NO: Failed to list untracked files"
    exit 1
  end
  additional_exclusions = [
    "*.log", "*.tmp", "*.temp", "*.bak", "*.swp", "*.swo",
    "*.pyc", "*.pyo", "*.class", "*.jar", "*.war", "*.ear",
    "*.zip", "*.tar.gz", "*.tgz", "*.rar", "*.exe", "*.dll",
    "*.so", "*.dylib", "*.bin", "*.dat", "*.orig", "*.rej",
    ".DS_Store", "Thumbs.db"
  ]
  files_to_add = all_untracked.reject do |file|
    additional_exclusions.any? { |pattern| File.fnmatch(pattern, File.basename(file)) }
  end

  return if files_to_add.empty?

  add_cmd = ["git", "-C", project_root, "add", "-N", *files_to_add].map { |p| Shellwords.escape(p) }.join(" ")
  system("#{add_cmd} 2>/dev/null")
end

def get_diff_output(project_root: PROJECT_ROOT)
  diff_output = `git -C #{Shellwords.escape(project_root)} diff -U500`
  unless $?.success?
    puts "NO: Failed to capture diff for analysis"
    exit 1
  end
  diff_output
end

CompletionNotifier.setup_exit_hook

debug_mode, _cli_hint = parse_arguments(ARGV)
feature_request = get_feature_request(ARGV)

status_output = run_cmd("git status --porcelain --branch")

  if status_output.lines.count { |line| !line.start_with?("##") }.zero?
    puts "NO: No changes to assess."
    exit 1
  end

  prepare_untracked_files
  diff_output = get_diff_output

  response = Verify.new(debug: debug_mode, project_root: PROJECT_ROOT).assess_feature(
    feature_request,
    status_output,
    diff_output
  )

  verified, description = parse_response(response)
  display_result(verified, description)
