#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/openai_client"
require_relative "lib/agents_file_handler"
require_relative "lib/completion_notifier"
require "shellwords"
require "rbconfig"
require "colorize"
require "json"

# Simple system information detection with memoization
class SystemInfo
  def self.to_s
    @system_info ||= begin
      platform = detect_platform
      version = detect_version(platform)
      desktop = detect_desktop
      shell = detect_shell

      "OS: #{platform}#{version.empty? ? "" : ", Version: #{version}"}" \
        "#{desktop.empty? ? "" : ", Desktop: #{desktop}"}" \
        "#{shell.empty? ? "" : ", Shell: #{shell}"}"
    rescue
      ""
    end
  end

  def self.detect_platform
    case RbConfig::CONFIG["host_os"].downcase
    when /darwin/ then "macOS"
    when /linux/ then detect_linux_platform
    when /mswin|mingw|cygwin/ then "Windows"
    else RbConfig::CONFIG["host_os"]
    end
  end

  def self.detect_linux_platform
    return "Ubuntu" if ubuntu_os_release?

    "Linux"
  end

  def self.ubuntu_os_release?
    File.exist?("/etc/os-release") &&
      File.read("/etc/os-release") =~ /^NAME="?Ubuntu"?/i
  end

  def self.detect_version(platform)
    case platform
    when "macOS" then `sw_vers -productVersion 2>/dev/null`.strip
    when "Ubuntu" then ubuntu_version
    when "Windows" then `wmic os get Version /value 2>NUL`.split("=").last.to_s.strip
    else ""
    end
  end

  def self.ubuntu_version
    return "" unless File.exist?("/etc/os-release")

    match = File.read("/etc/os-release").match(/^VERSION="?([^"\n]+)"?/)
    match ? match[1].strip : ""
  end

  def self.detect_desktop
    return ENV["XDG_CURRENT_DESKTOP"].to_s unless ENV["XDG_CURRENT_DESKTOP"].to_s.empty?
    return ENV["DESKTOP_SESSION"].to_s unless ENV["DESKTOP_SESSION"].to_s.empty?
    return "GNOME" if ENV["GNOME_DESKTOP_SESSION_ID"]
    return "KDE" if ENV["KDE_FULL_SESSION"] == "true"

    ""
  end

  def self.detect_shell
    shell_path = ENV["SHELL"]
    return "" unless shell_path

    File.basename(shell_path)
  rescue
    ""
  end
end

# Class to interact with OpenAI API
class OpenAi
  include AgentsFileHandler

  def initialize(model: nil, debug: false)
    @client = OpenAiClient.new(model: model, debug: debug,
      progress_title: "Generating command")
    @debug = debug
  end

  # Method to send prompts to OpenAI and get a response
  def ask(prompts, json: false)
    @client.ask(prompts, json: json)
  end

  def analyze_request(user_instruction)
    system_instruction = <<~HEREDOC
      Analyze the user's request and determine if additional context is needed.

      Available context:
      #{system_context}

      Return value format: JSON object with these optional fields:
      - context_commands: array of command strings to gather additional context
      - bash_command: the bash command to execute

      Critical rules:
      - NEVER return {"context_commands": [], "bash_command": null} - this is invalid
      - If request can be answered with available context, return bash_command directly
      - If you need additional system output, return context_commands (non-empty array)
      - If context_commands provided, omit bash_command field entirely
      - If bash_command provided, omit context_commands field entirely
      - If both fields omitted, return empty JSON object {}
      - context_commands array MUST be non-empty if provided
      - bash_command MUST be non-empty string if provided
      - Use context_commands only when available context is insufficient

      Examples:
      - User: "create git commit" → {"context_commands": ["git status", "git diff"]}
      - User: "list files" → {"bash_command": "ls -la"}
      - User: "run tests" → {"context_commands": ["ls", "cat package.json"]}
      - User: "show current directory" → {"bash_command": "pwd"}
      - User: "what os am I running" → {"bash_command": "uname -a"}
    HEREDOC

    response = ask([
      {role: "system", content: system_instruction},
      {role: "user", content: user_instruction}
    ], json: true)

    JSON.parse(response || "{}")
  rescue JSON::ParserError => e
    warn "JSON parsing error: #{e.message}" if @debug
    warn "Raw response: #{response}" if @debug
    {}
  end

  def collect_context_output(commands)
    return "" if commands.empty?

    output = commands.map do |cmd|
      puts "Collecting context: #{cmd}".cyan
      result = `#{cmd} 2>&1` rescue ""
      puts result unless result.empty?
      truncated = result.lines.first(20).join
      "#{cmd}\n#{truncated}"
    end

    output.join("\n\n---\n\n")
  end

  # Method to refactor code based on user instructions
  def bash_command(user_instruction, context_output = "")
    system_instruction = build_system_instruction(context_output)
    ask([
      {role: "system", content: system_instruction},
      {role: "user", content: user_instruction}
    ]).gsub(/^```.*\n?/, "")
  end

  private

  def build_system_instruction(context_output = "")
    parts = [base_instruction]
    parts << agents_instruction if has_agents?
    parts << context_section(context_output) unless context_output.empty?
    parts << system_context
    parts.join
  end

  def context_section(output)
    <<~HEREDOC

      Context from system commands:
      #{output}

    HEREDOC
  end

  def base_instruction
    "Generate a bash command to accomplish the user's request.\n" \
      "Return the command only."
  end

  def agents_instruction
    <<~HEREDOC

      When generating commands, carefully review the AGENTS.md content below for:
      - Specific command examples and patterns
      - Testing commands (e.g., npm test, pytest, rspec, etc.)
      - Build commands (e.g., npm run build, make, cargo build, etc.)
      - Linting commands (e.g., npm run lint, ruff, rubocop, etc.)
      - Any project-specific bash command guidelines
      Pay special attention to testing and build commands when the user request involves running tests or building the project.

      AGENTS.md content (development guidelines to follow):
      #{load_agents_file}

    HEREDOC
  end

  def system_context
    <<~HEREDOC

      System info:
      #{SystemInfo}

      Current directory:
      #{Dir.pwd}

      Directory listing:
      #{directory_listing}
    HEREDOC
  end

  def has_agents?
    !load_agents_file.empty?
  end

  def directory_listing
    entries = Dir.entries(Dir.pwd)
    entries = entries[0..48] + ["..."] if entries.length > 50
    entries.join("\n")
  end
end

# Parse arguments for debug mode
debug_mode = false
user_instruction_parts = []

ARGV.each do |arg|
  case arg
  when "--debug" then debug_mode = true
                      next
  end
  user_instruction_parts << arg
end

CompletionNotifier.setup_exit_hook

if user_instruction_parts.empty?
  puts "Usage: #{File.basename($PROGRAM_NAME)} [--debug] \"What to do\"".cyan
  exit
end

user_instruction = user_instruction_parts.join(" ")

ai = OpenAi.new(debug: debug_mode)

  result = ai.analyze_request(user_instruction)

  if debug_mode
    puts "AI Response:".yellow
    puts JSON.pretty_generate(result)
  end

  if result["context_commands"]&.any?
    context_output = ai.collect_context_output(result["context_commands"])
    bash_command = ai.bash_command(user_instruction, context_output)
  elsif result["bash_command"]
    bash_command = result["bash_command"]
  else
    bash_command = ai.bash_command(user_instruction)
  end

  safe_commands = %w[grep ag ls df cat less head tail sed awk tr uniq wc cut]

  print "Generated bash command: ".cyan
  puts bash_command.green

  if safe_commands.any? do |cmd|
    bash_command.start_with?(cmd + " ") || bash_command == cmd
  end
    puts "Running: #{bash_command}".green
    system(bash_command)
  else
    puts "Do you want to run this command? (y/N)".white
    answer = $stdin.gets.chomp.downcase

    if answer == "y"
      puts "Running: #{bash_command}".green
      system(bash_command)
    else
      puts "Command not executed.".yellow
    end
  end
