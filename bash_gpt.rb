#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'openai_client'
require 'shellwords'
require 'rbconfig'

# Simple system information detection with memoization
class SystemInfo
  def self.to_s
    @system_info ||= begin
      platform = case RbConfig::CONFIG['host_os'].downcase
                 when /darwin/ then 'macOS'
                 when /linux/ then File.exist?('/etc/os-release') && File.read('/etc/os-release') =~ /^NAME="?Ubuntu"?/i ? 'Ubuntu' : 'Linux'
                 when /mswin|mingw|cygwin/ then 'Windows'
                 else RbConfig::CONFIG['host_os']
                 end

      version = case platform
                when 'macOS' then `sw_vers -productVersion 2>/dev/null`.strip
                when 'Ubuntu' then File.exist?('/etc/os-release') && File.read('/etc/os-release') =~ /^VERSION="?([^"\n]+)"?/ ? Regexp.last_match(1).strip : ''
                when 'Windows' then `wmic os get Version /value 2>NUL`.split('=').last.to_s.strip
                else ''
                end

      desktop = if !ENV['XDG_CURRENT_DESKTOP'].to_s.empty?
                  ENV['XDG_CURRENT_DESKTOP'].to_s
                elsif !ENV['DESKTOP_SESSION'].to_s.empty?
                  ENV['DESKTOP_SESSION'].to_s
                elsif ENV['GNOME_DESKTOP_SESSION_ID']
                  'GNOME'
                elsif ENV['KDE_FULL_SESSION'] == 'true'
                  'KDE'
                else
                  ''
                end

      shell = detect_shell

      "OS: #{platform}" +
        (version.empty? ? '' : ", Version: #{version}") +
        (desktop.empty? ? '' : ", Desktop: #{desktop}") +
        (shell.empty? ? '' : ", Shell: #{shell}")
    rescue StandardError
      ''
    end
  end

  def self.detect_shell
    shell_path = ENV['SHELL']
    return '' unless shell_path

    File.basename(shell_path)
  rescue StandardError
    ''
  end
end

# Class to interact with OpenAI API
class OpenAi
  def initialize(model: 'gpt-5.1', debug: false)
    @client = OpenAiClient.new(model: model, debug: debug)
  end

  # Method to send prompts to OpenAI and get a response
  def ask(prompts)
    @client.ask(prompts)
  end

  # Method to refactor code based on user instructions
  def bash_command(user_instruction)
    system_info = SystemInfo.to_s
    current_directory = Dir.pwd

    # Get directory listing, limit to 50 entries with '...' if more
    entries = Dir.entries(current_directory)
    entries = entries[0..48] + ['...'] if entries.length > 50
    directory_listing = entries.join("\n")

    system_instruction = <<~HEREDOC
      Generate a bash command to accomplish the user's request.
      Return the command only.

      System info:
      #{system_info}

      Current directory:
      #{current_directory}

      Directory listing:
      #{directory_listing}
    HEREDOC

    ask([{ role: 'system', content: system_instruction },
         { role: 'user', content: user_instruction }])
      .gsub(/^```.*\n?/, '')
  end
end

# Parse arguments for debug and search modes
debug_mode = false
search_mode = false
user_instruction_parts = []

ARGV.each do |arg|
  case arg
  when '--debug' then debug_mode = true
                      next
  when '--search' then search_mode = true
                       next
  end
  user_instruction_parts << arg
end

if user_instruction_parts.empty?
  puts "Usage: #{File.basename($PROGRAM_NAME)} [--debug] [--search] \"What to do\""
  exit
end

user_instruction = user_instruction_parts.join(' ')
model = search_mode ? 'gpt-4o-search-preview' : 'gpt-5.1'
bash_command = OpenAi.new(model: model, debug: debug_mode).bash_command(user_instruction)

safe_commands = %w[grep ag ls df cat less head tail sed awk tr uniq wc cut]

puts "Generated bash command:\n#{bash_command}"
if safe_commands.any? { |cmd| bash_command.start_with?(cmd + ' ') || bash_command == cmd }
  system(bash_command)
else
  puts 'Do you want to run this command? (y/n)'
  answer = STDIN.gets.chomp.downcase

  if answer == 'y'
    system(bash_command)
  else
    puts 'Command not executed.'
  end
end
