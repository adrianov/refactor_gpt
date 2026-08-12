# frozen_string_literal: true

require 'rbconfig'

# Static system rules and dynamic host context for bash_gpt.rb.
# Host state (cwd, listing, command output) belongs on the user turn so the system
# prompt stays cacheable across different working-tree changes.
module BashPrompt
  module_function

  def analyze_system_instruction
    <<~HEREDOC
      Analyze the user's request and determine if additional context is needed.

      The user message includes available host context (OS, cwd, directory listing).

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
  end

  def command_system_instruction
    "Generate a bash command to accomplish the user's request.\n" \
      "Return the command only."
  end

  def analyze_messages(user_instruction, host_context: nil)
    [
      {role: 'system', content: analyze_system_instruction},
      {role: 'user', content: user_message(user_instruction, host_context: host_context)}
    ]
  end

  def command_messages(user_instruction, host_context: nil, context_output: '')
    [
      {role: 'system', content: command_system_instruction},
      {role: 'user',
       content: user_message(user_instruction, host_context: host_context, context_output: context_output)}
    ]
  end

  def user_message(user_instruction, host_context: nil, context_output: '')
    parts = [user_instruction.to_s]
    parts << "\n\nHost context:\n#{host_context}" unless host_context.to_s.empty?
    parts << "\n\nContext from system commands:\n#{context_output}" unless context_output.to_s.empty?
    parts.join
  end

  def host_context(pwd: Dir.pwd, listing: nil, system_info: nil)
    listing = directory_listing(pwd) if listing.nil?
    info = system_info.nil? ? BashHostInfo.to_s : system_info
    <<~HEREDOC.strip
      System info:
      #{info}

      Current directory:
      #{pwd}

      Directory listing:
      #{listing}
    HEREDOC
  end

  def directory_listing(pwd = Dir.pwd)
    entries = Dir.entries(pwd)
    entries = entries[0..48] + ['...'] if entries.length > 50
    entries.join("\n")
  end
end

# Host details for bash_gpt (OS, version, desktop, shell).
class BashHostInfo
  def self.to_s
    @to_s ||= begin
      platform = detect_platform
      version = detect_version(platform)
      desktop = detect_desktop
      shell = detect_shell
      "OS: #{platform}#{version.empty? ? '' : ", Version: #{version}"}" \
        "#{desktop.empty? ? '' : ", Desktop: #{desktop}"}" \
        "#{shell.empty? ? '' : ", Shell: #{shell}"}"
    rescue StandardError
      ''
    end
  end

  def self.detect_platform
    case RbConfig::CONFIG['host_os'].downcase
    when /darwin/ then 'macOS'
    when /linux/ then ubuntu_os_release? ? 'Ubuntu' : 'Linux'
    when /mswin|mingw|cygwin/ then 'Windows'
    else RbConfig::CONFIG['host_os']
    end
  end

  def self.ubuntu_os_release?
    File.exist?('/etc/os-release') && File.read('/etc/os-release') =~ /^NAME="?Ubuntu"?/i
  end

  def self.detect_version(platform)
    case platform
    when 'macOS' then `sw_vers -productVersion 2>/dev/null`.strip
    when 'Ubuntu' then ubuntu_version
    when 'Windows' then `wmic os get Version /value 2>NUL`.split('=').last.to_s.strip
    else ''
    end
  end

  def self.ubuntu_version
    return '' unless File.exist?('/etc/os-release')

    match = File.read('/etc/os-release').match(/^VERSION="?([^"\n]+)"?/)
    match ? match[1].strip : ''
  end

  def self.detect_desktop
    return ENV['XDG_CURRENT_DESKTOP'].to_s unless ENV['XDG_CURRENT_DESKTOP'].to_s.empty?
    return ENV['DESKTOP_SESSION'].to_s unless ENV['DESKTOP_SESSION'].to_s.empty?
    return 'GNOME' if ENV['GNOME_DESKTOP_SESSION_ID']
    return 'KDE' if ENV['KDE_FULL_SESSION'] == 'true'

    ''
  end

  def self.detect_shell
    shell_path = ENV['SHELL']
    return '' unless shell_path

    File.basename(shell_path)
  rescue StandardError
    ''
  end
end
