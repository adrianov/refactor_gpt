#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/loader'
require 'shellwords'

# Builds and runs an `ag` search from a natural-language request.
class AgGpt
  def initialize
    @client = OpenAiClient.new(progress_title: 'Searching code')
  end

  def ask(prompts, json: false)
    @client.ask(prompts, json: json)
  end

  def bash_command(user_instruction)
    keywords = list_code_file_keywords
    keywords = Dir.entries(Dir.pwd) if keywords.empty?
    ask(AgPrompt.search_messages(user_instruction, project_keywords: keywords.join(' ')[0..4096]))
      .gsub(/^```.*\n?/, '')
  end

  def interpret_ag_output(user_instruction, ag_output)
    ask(AgPrompt.interpret_messages(user_instruction, ag_output))
  end

  def list_code_file_keywords
    return [] unless system("git --version > #{File::NULL} 2>&1")

    files = `git ls-files`.split("\n")
    extensions = %w[
      .rb .py .js .java .php .cpp .c .go .sh .html .css .yml .erb .slim .rs .ts
      .swift .kt .scala .pl .pm .r .jl
    ]
    code_files = files.select { |file| extensions.any? { |ext| file.end_with?(ext) } }
    code_files = code_files.sort_by { |file| [file.count('/'), file] }
    code_files.flat_map { |file| file.scan(/[a-zA-Z]+/) }.uniq
  end
end

def check_ag_installed
  system("ag --version > #{File::NULL} 2>&1")
end

unless check_ag_installed
  warn "'ag' (The Silver Searcher) is not installed. Please install it to proceed."
  exit 1
end

CompletionNotifier.setup_exit_hook

if ARGV.empty?
  puts 'Search through your code with human language.'
  puts "Usage: #{File.basename($PROGRAM_NAME)} \"What to search in human language\""
  exit 0
end

user_instruction = ARGV.join(' ')
openai = AgGpt.new
bash_command = openai.bash_command(user_instruction)

puts "Generated bash command: #{bash_command}"

answer = if bash_command.start_with?('ag ')
           puts ''
           'y'
         else
           puts 'Do you want to run this command? (y/n)'
           PromptReader.read_line('', downcase: true)
         end

if answer == 'y'
  system(bash_command)
  puts "\nFinished:\n#{bash_command}"

  unless `#{bash_command}`.strip.empty?
    puts "\nInterpret results with OpenAI? (y/N)"
    interpret_answer = PromptReader.read_line('', downcase: true)

    if interpret_answer == 'y'
      puts "\nInterpreting results with OpenAI..."
      interpretation = openai.interpret_ag_output(user_instruction, `#{bash_command}`)
      if system('command -v glow >/dev/null 2>&1')
        IO.popen(%w[glow -], 'w') { |io| io.write(interpretation) }
      else
        puts "\nOpenAI interpretation:\n\n#{interpretation}"
      end
    end
  end
else
  puts 'Command not executed.'
end
