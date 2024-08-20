#!/usr/bin/env ruby
require 'net/http'
require 'oj'

# Class to interact with OpenAI API
class OpenAi
  def initialize
    @api_base_url = fetch_env('OPENAI_BASE_URL')
    @api_key = fetch_env('OPENAI_ACCESS_TOKEN')
    @model = 'gpt-4o'
    @temperature = 0
  end

  # Send prompts to OpenAI API and get a response
  def ask(prompts)
    uri = URI("#{@api_base_url}/chat/completions")
    request = create_post_request(uri, prompts)
    response = send_request(uri, request)
    parse_response(response)
  end

  # Refactor code using OpenAI
  def refactor(code, additional_instructions = nil)
    instruction = <<~HEREDOC
      Return the complete refactored code block only without explanations.

      1. Error Handling: Identify and fix any errors by rewriting the affected sections if necessary.
      2. Descriptive Naming: Use clear and descriptive variable names.
      3. Function Length: Ensure all functions are shorter than 15 lines, and all lines are not longer than 80 characters.
      4. Inline Variables: If a variable used only once, replace it with its value.
      5. Simplify Logic: Reduce the number of assignments, branches, and conditions.
      6. Comments: Add a brief comment before each class or function to explain its purpose.
      7. Preserve Logic: Maintain all existing business logic.
      8. Complete TODO

      #{'Additional user instructions: ' + additional_instructions + '.' if additional_instructions}
    HEREDOC

    ask([{ role: 'system', content: instruction }, { role: 'user', content: code }]).gsub(/^```.*\n?/, '')
  end

  private

  # Create a POST request
  def create_post_request(uri, prompts)
    Net::HTTP::Post.new(uri, 
      'Content-Type' => 'application/json', 
      'Authorization' => "Bearer #{@api_key}").tap do |request|
        request.body = Oj.dump({ model: @model, temperature: @temperature, messages: prompts }, mode: :compat, symbol_keys: true)
      end
  end

  # Send HTTP request
  def send_request(uri, request)
    Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 100) do |http|
      http.request(request)
    end
  end

  # Parse the response and handle errors
  def parse_response(response)
    answer = Oj.load(response.body).dig('choices', 0, 'message', 'content')
    handle_missing_answer(response) if answer.nil? || answer.empty?
    answer
  end

  # Fetch environment variables from .env file
  def fetch_env(key, default = nil)
    @env_vars ||= load_env_vars
    @env_vars.fetch(key, default)
  end

  # Load environment variables into a hash
  def load_env_vars
    env_file = File.join(File.dirname(__FILE__), '.env')
    return {} unless File.exist?(env_file)

    File.foreach(env_file).with_object({}) do |line, env_vars|
      key, value = line.split('=')
      env_vars[key.strip] = value.strip if key && value
    end
  end

  # Handle missing answer response
  def handle_missing_answer(response)
    puts response.body
    exit
  end
end

# Main execution block
if ARGV.empty?
  puts "Please provide a file path as an argument."
  exit
end

file_path = ARGV[0]
unless File.exist?(file_path)
  puts "File not found: #{file_path}"
  exit
end

code = File.binread(file_path)
additional_instructions = ARGV[1..-1].join(' ') if ARGV.length > 1
refactored_code = OpenAi.new.refactor(code, additional_instructions)
refactored_code += "\n" if refactored_code[-1] != "\n"

if code == refactored_code
  puts "No changes made."
  exit
end

backup_file_path = "#{file_path}.bak"
File.binwrite(backup_file_path, code) unless system('git rev-parse --is-inside-work-tree')
File.binwrite(file_path, refactored_code)
puts refactored_code
