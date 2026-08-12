#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/loader'
require 'colorize'
require 'oj'

# Generates and optionally runs a bash command from a natural-language request.
class BashGpt
  include AgentsFileHandler

  def initialize(model: nil, debug: false)
    @client = OpenAiClient.new(model: model, debug: debug, progress_title: 'Generating command')
    @debug = debug
  end

  def ask(prompts, json: false)
    @client.ask(prompts, json: json)
  end

  def analyze_request(user_instruction)
    response = ask(BashPrompt.analyze_messages(user_instruction, host_context: BashPrompt.host_context), json: true)
    Oj.load(response || '{}')
  rescue Oj::ParseError => e
    warn "JSON parsing error: #{e.message}" if @debug
    warn "Raw response: #{response}" if @debug
    {}
  end

  def collect_context_output(commands)
    return '' if commands.empty?

    commands.map do |cmd|
      puts "Collecting context: #{cmd}".cyan
      result = begin
        `#{cmd} 2>&1`
      rescue StandardError
        ''
      end
      puts result unless result.empty?
      "#{cmd}\n#{result.lines.first(20).join}"
    end.join("\n\n---\n\n")
  end

  def bash_command(user_instruction, context_output = '')
    ask(
      BashPrompt.command_messages(
        user_instruction,
        host_context: BashPrompt.host_context,
        context_output: context_output
      )
    ).gsub(/^```.*\n?/, '')
  end
end

debug_mode = false
user_instruction_parts = []

ARGV.each do |arg|
  case arg
  when '--debug' then debug_mode = true
                      next
  end
  user_instruction_parts << arg
end

CompletionNotifier.setup_exit_hook

if user_instruction_parts.empty?
  puts "Usage: #{File.basename($PROGRAM_NAME)} [--debug] \"What to do\"".cyan
  exit 0
end

user_instruction = user_instruction_parts.join(' ')
ai = BashGpt.new(debug: debug_mode)
result = ai.analyze_request(user_instruction)

if debug_mode
  puts 'AI Response:'.yellow
  puts Oj.dump(result, mode: :compat, indent: 2)
end

bash_command = if result['context_commands']&.any?
                 ai.bash_command(user_instruction, ai.collect_context_output(result['context_commands']))
               elsif result['bash_command']
                 result['bash_command']
               else
                 ai.bash_command(user_instruction)
               end

safe_commands = %w[grep ag ls df cat less head tail sed awk tr uniq wc cut]

print 'Generated bash command: '.cyan
puts bash_command.green

if safe_commands.any? { |cmd| bash_command.start_with?("#{cmd} ") || bash_command == cmd }
  puts "Running: #{bash_command}".green
  system(bash_command)
else
  puts 'Do you want to run this command? (y/N)'.white
  answer = PromptReader.read_line('', downcase: true)

  if answer == 'y'
    puts "Running: #{bash_command}".green
    system(bash_command)
  else
    puts 'Command not executed.'.yellow
  end
end
