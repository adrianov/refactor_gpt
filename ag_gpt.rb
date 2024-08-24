#!/usr/bin/env ruby
require 'net/http'
require 'oj'
require 'shellwords'

# Class to interact with OpenAI API
class OpenAi
  def initialize
    @api_base_url = fetch_env('OPENAI_BASE_URL')
    @api_key = fetch_env('OPENAI_ACCESS_TOKEN')
    @model = 'gpt-4o-mini'
    @temperature = 0
  end

  # Method to send prompts to OpenAI and get a response
  def ask(prompts)
    uri = URI("#{@api_base_url}/chat/completions")
    response = send_request(uri, prompts)
    parse_response(response)
  end

  # Method to refactor code based on user instructions
  def bash_command(user_instruction)
    system_instruction = <<~HEREDOC
      Task: Search through the software repository using ag (The Silver Searcher) to answer the user's request.
      
      1. Current Directory Contents:
         #{Dir.entries(Dir.pwd).join("\n")}
      
      2. Steps:
          - Identify the framework used in the repository.
          - Narrow down the specific files that are likely to contain relevant code.
          - Identify multiple non-trivial code variants that could address the user's request.
          - Create regex patterns to match these code variants.
          - Combine these patterns into a single search regex.
          - Expand the regex with synonyms and many related library names for comprehensive search coverage.
      
      3. Command Formation:
          - Use ag to search, ignoring minified files: 
            ag --ignore '*.min.*' search_regex
      
      4. Output:
          - Provide only the ag command.
    HEREDOC

    ask([{ role: 'system', content: system_instruction },
         { role: 'user', content: user_instruction }])
      .gsub(/^```.*\n?/, '')
  end

  # Method to send the HTTP request
  def send_request(uri, prompts)
    request = Net::HTTP::Post.new(uri,
                                  'Content-Type' => 'application/json',
                                  'Authorization' => "Bearer #{@api_key}")
    request.body = Oj.dump({ model: @model, temperature: @temperature,
                             messages: prompts }, mode: :compat)

    Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https',
                    read_timeout: 100) do |http|
      http.request(request)
    end
  end

  # Method to parse the response from OpenAI
  def parse_response(response)
    answer = Oj.load(response.body).dig('choices', 0, 'message', 'content')
    handle_missing_answer(response) if answer.nil? || answer.empty?
    answer
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
