#!/usr/bin/env ruby
require 'excon'
require 'oj'
require 'shellwords'

# Class to interact with OpenAI API
class OpenAi
  def initialize
    @api_base_url = fetch_env('OPENAI_BASE_URL')
    @api_key = fetch_env('OPENAI_ACCESS_TOKEN')
    @model = 'gpt-4o'
    @temperature = 0
  end

  # Method to send prompts to OpenAI and get a response
  def ask(prompts)
    response = Excon.post(
      "#{@api_base_url}/chat/completions",
      headers: {
        'Content-Type' => 'application/json',
        'Authorization' => "Bearer #{@api_key}"
      },
      body: Oj.dump({ model: @model, temperature: @temperature, messages: prompts }, mode: :compat),
      read_timeout: 20
    )
    answer = Oj.load(response.body).dig('choices', 0, 'message', 'content')
    handle_missing_answer(response) if answer.nil? || answer.empty?
    answer
  end

  # Method to refactor code based on user instructions
  def bash_command(user_instruction)
    project_keywords = list_code_file_keywords
    project_keywords = Dir.entries(Dir.pwd) if project_keywords.empty?
    project_keywords = project_keywords.join(' ')[0..4096]

    system_instruction = <<~HEREDOC
      Task: Use `ag` (The Silver Searcher) to search through the software repository and answer the user's request.

      1. Project Keywords:
         #{project_keywords}

      2. Steps:
         - Determine the framework and programming language used.
         - Think of many variants how the user's request could be implemented in the code.
         - Select extensive list of project keywords for matching the implementation.
         - Create the search regex. Examples:
            \\b(user|session).*?(quit|close)
            \\b(waiting|list).*?(mail|deliver)
         - Always expand the regex with synonyms, many library names, framework and language specific keywords.

      3. Command Formation:
         - Construct the `ag` command to search, excluding minified files.
           ag --ignore '*.min.*' --ruby 'search_regex' Gemfile .

      4. Output: Provide only the complete ag command without any other text.
    HEREDOC

    ask([{ role: 'system', content: system_instruction },
         { role: 'user', content: user_instruction }])
      .gsub(/^```.*\n?/, '')
  end

  def list_code_file_keywords
    return [] unless system("git --version > #{File::NULL} 2>&1")

    # Get all files in the repository
    files = `git ls-files`.split("\n")

    # Define the extensions to include
    extensions = %w[.rb .py .js .java .php .cpp .c .go .sh .html .css .yml .erb .slim .rs .ts .swift .kt .scala .pl .pm .r .jl]

    # Filter files based on the extensions
    code_files = files.select do |file|
      extensions.any? { |ext| file.end_with?(ext) }
    end

    # Tokenize file names by words
    code_files.flat_map do |file|
      file.scan(/[a-zA-Z]+/)
    end.uniq
  end

  # Method to fetch environment variables
  def fetch_env(key, default = nil)
    @env_vars ||= load_env_vars
    value = @env_vars.fetch(key, ENV[key] || default)
    if value.nil?
      puts "Missing required environment variable: #{key}. Please add it to the .env file."
      exit
    end
    value
  end

  # Method to load environment variables from a file
  def load_env_vars
    env_file = File.join(File.dirname(__FILE__), '.env')
    return {} unless File.exist?(env_file)

    File.foreach(env_file).with_object({}) do |line, env_vars|
      key, value = line.split('=')
      env_vars[key.strip] = value.strip if key && value
    end
  end

  # Method to handle missing answers in the response
  def handle_missing_answer(response)
    puts response.body
    exit
  end
end

# Check if 'ag' is installed
def check_ag_installed
  system("ag --version > #{File::NULL} 2>&1")
end

unless check_ag_installed
  puts "'ag' (The Silver Searcher) is not installed. Please install it to proceed."
  exit
end

if ARGV.empty?
  puts 'Search through your code with human language.'
  puts "Usage: #{File.basename($PROGRAM_NAME)} \"What to search in human language\""
  exit
end

user_instruction = ARGV.join(' ')
bash_command = OpenAi.new.bash_command(user_instruction)

puts "Generated bash command:\n#{bash_command}"

# Run the command automatically if it starts with 'ag'
answer = if bash_command.start_with?('ag ')
           puts ''
           'y'
         else
           puts "Do you want to run this command? (y/n)"
           STDIN.gets.chomp.downcase
         end

if answer == 'y'
  system(bash_command)
  puts "\nFinished:\n#{bash_command}"
else
  puts "Command not executed."
end
