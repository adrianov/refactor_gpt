#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'openai_client'
require 'shellwords'

# Class to interact with OpenAI API
class OpenAi
  def initialize
    @client = OpenAiClient.new
  end

  # Method to send prompts to OpenAI and get a response
  def ask(prompts)
    @client.ask(prompts)
  end

  # Method to refactor code based on user instructions
  def bash_command(user_instruction)
    project_keywords = list_code_file_keywords
    project_keywords = Dir.entries(Dir.pwd) if project_keywords.empty?
    project_keywords = project_keywords.join(' ')[0..4096]

    system_instruction = <<~HEREDOC
      Task: Use `ag` (The Silver Searcher) to search through the software repository and answer the user's request by outputting a single shell command.

      High-level behavior:
      - Construct a plain `ag` command that directly searches for the most relevant pattern(s) based on the user's request.
      - Keep this `ag` usage simple and broad so you do not accidentally miss real results.
      - Do NOT use any additional Unix text-processing tools (no awk/sed/cut/sort/uniq/tr/grep/etc.). Only `ag` is allowed.

      1. Project Context:
         - Keywords and file-name tokens (BFS-ordered by directory depth):
           #{project_keywords}

      2. Repository Navigation Strategy:
         - Prefer breadth-first traversal of directories (shallow paths first) when reasoning about where code might live.
         - When the user asks for a specific module, class, or file by name (not by its text content):
           * Infer likely file paths using common conventions (e.g. snake_case for Ruby, matching directory names, etc.).
           * Use `ag -g` (file name search) with an appropriate pattern to locate candidate files.
           * Example:
             - User: "find UserService module"
               Command: ag -g 'UserService' .
             - User: "find user_service.rb"
               Command: ag -g 'user_service\\.rb' .

      3. Content Search:
         - Default behavior:
           * Use a plain `ag` search that is likely to capture all relevant occurrences.
           * Example:
             - User: "List all widget types"
               ag --ignore '*.min.*' 'widget' .
           * This ensures you do not miss real results due to overly strict parsing.
         - Do NOT append any pipelines or additional commands. Only a single `ag` invocation is allowed.

      4. Command Formation:
         - If the request is primarily about locating files/modules by name:
           * Prefer `ag -g 'name_pattern' .`
         - Otherwise (text/content based search):
           * Construct the `ag` command to search, excluding minified files:
             ag --ignore '*.min.*' 'search_regex' .
         - Always:
           * Escape regex metacharacters in literal file names where appropriate (e.g. `.` -> `\\.`).
           * Keep the command on a single line.
           * Use `.` as the search root unless the user clearly specifies another directory.

      5. Output:
         - Provide only the complete shell command without any other text.
         - Do not wrap the command in backticks or quotes.
    HEREDOC

    ask([
          { role: 'system', content: system_instruction },
          { role: 'user', content: user_instruction }
        ]).gsub(/^```.*\n?/, '')
  end

  def interpret_ag_output(user_instruction, ag_output)
    interpretation_system_instruction = <<~HEREDOC
      You are helping a developer understand the results of running `ag` (The Silver Searcher) on their codebase.

      The user asked a question about their code. An `ag` search was run to find relevant matches.
      You will be given:
      - The user's original natural-language question.
      - The raw `ag` output (file:line:matched text).

      Your task:
      - Interpret the `ag` results in the context of the user's question.
      - Explain what in the codebase appears relevant to their question.
      - Summarize key files, lines, and patterns that matter.
      - If appropriate, infer how the code works or where they might need to look next.
      - If the results seem incomplete or noisy, say so and explain why.

      Be concise but specific. Refer to files and line numbers when helpful.
    HEREDOC

    ask([
          { role: 'system', content: interpretation_system_instruction },
          { role: 'user',
            content: <<~HEREDOC
              User question:
              #{user_instruction}

              ag output:
              #{ag_output}
            HEREDOC
          }
        ])
  end

  def list_code_file_keywords
    return [] unless system("git --version > #{File::NULL} 2>&1")

    # Get all files in the repository
    files = `git ls-files`.split("\n")

    # Define the extensions to include
    extensions = %w[
      .rb .py .js .java .php .cpp .c .go .sh .html .css .yml .erb .slim .rs .ts
      .swift .kt .scala .pl .pm .r .jl
    ]

    # Filter files based on the extensions
    code_files = files.select do |file|
      extensions.any? { |ext| file.end_with?(ext) }
    end

    # Sort files using BFS-like directory traversal order (by path depth, then lexicographically)
    code_files = code_files.sort_by { |file| [file.count('/'), file] }

    # Tokenize file names by words
    code_files.flat_map do |file|
      file.scan(/[a-zA-Z]+/)
    end.uniq
  end
end

# Check if 'ag' is installed
def check_ag_installed
  system("ag --version > #{File::NULL} 2>&1")
end

unless check_ag_installed
  warn "'ag' (The Silver Searcher) is not installed. Please install it to proceed."
  exit(1)
end

if ARGV.empty?
  puts 'Search through your code with human language.'
  puts "Usage: #{File.basename($PROGRAM_NAME)} \"What to search in human language\""
  exit(0)
end

user_instruction = ARGV.join(' ')
openai = OpenAi.new
bash_command = openai.bash_command(user_instruction)

puts "Generated bash command:\n#{bash_command}"

# Run the command automatically if it starts with 'ag'
answer = if bash_command.start_with?('ag ')
           puts ''
           'y'
         else
           puts 'Do you want to run this command? (y/n)'
           STDIN.gets.to_s.chomp.downcase
         end

if answer == 'y'
  system(bash_command)
  puts "\nFinished:\n#{bash_command}"

  ag_output = `#{bash_command}`
  unless ag_output.strip.empty?
    puts "\nInterpret results with OpenAI? (y/N)"
    interpret_answer = STDIN.gets&.chomp&.downcase

    if interpret_answer == 'y'
      puts "\nInterpreting results with OpenAI..."
      interpretation = openai.interpret_ag_output(user_instruction, ag_output)
      if system('command -v glow >/dev/null 2>&1')
        IO.popen(['glow', '-'], 'w') { |io| io.write(interpretation) }
      else
        puts "\nOpenAI interpretation:\n\n#{interpretation}"
      end
    end
  end
else
  puts 'Command not executed.'
end
