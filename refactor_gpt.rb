#!/usr/bin/env ruby
require 'net/http'
require 'oj'

# Class to interact with OpenAI API
class OpenAi
  def initialize
    @api_base_url = fetch_env_variable('OPENAI_BASE_URL')
    @api_key = fetch_env_variable('OPENAI_ACCESS_TOKEN')
    @model = 'gpt-4o'
  end

  # Method to send prompts to OpenAI API and get a response
  def ask(prompts)
    uri = URI("#{@api_base_url}/chat/completions")
    request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json', 'Authorization' => "Bearer #{@api_key}")
    request.body = Oj.dump({ model: @model, messages: prompts }, mode: :compat, symbol_keys: true)
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 100) { |http| http.request(request) }
    parse_response(response)
  end

  # Method to parse the response and handle errors
  def parse_response(response)
    answer = Oj.load(response&.body.to_s).dig('choices', 0, 'message', 'content') rescue {}
    return answer unless answer.nil? || answer.empty?

    puts response.body.to_s
    exit
  end

  # Method to refactor code using OpenAI
  def refactor(code, additional_instructions = nil)
    instruction = <<~HEREDOC
      Return the complete refactored code block only without explanations.

      1. Error Handling: Identify and fix any errors by rewriting the affected sections if necessary.
      2. Descriptive Naming: Use clear and descriptive variable names.
      3. Function Length: Ensure all functions are shorter than 15 lines.
      4. Inline Variables: If a variable used only once, replace it with its value.
      5. Simplify Logic: Reduce the number of assignments, branches, and conditions.
      6. Comments: Add a brief comment before each class or function to explain its purpose.
      7. Preserve Logic: Maintain all existing business logic.
      8. Complete TODO

      #{additional_instructions ? 'Additional user instructions: ' + additional_instructions + '.' : ''}
    HEREDOC

    ask([
          { role: 'system', content: instruction },
          { role: 'user', content: code }
        ]).gsub(/^```.*\n?/, '')
  end

  private

  # Method to fetch environment variables from .env file
  def fetch_env_variable(key, default = nil)
    @env_vars ||= load_env_vars
    @env_vars.fetch(key, default)
  end

  # Method to load environment variables into a hash
  def load_env_vars
    env_file = File.join(File.dirname(__FILE__), '.env')
    return {} unless File.exist?(env_file)

    env_vars = {}
    File.foreach(env_file) do |line|
      key, value = line.split('=')
      env_vars[key.strip] = value.strip if key && value
    end
    env_vars
  end
end

if ARGV.empty?
  puts "Please provide a file path as an argument."
  exit
end

file_path = ARGV[0]

unless File.exist?(file_path)
  puts "File not found: #{file_path}"
  exit
end

code = File.read(file_path)

additional_instructions = ARGV.length > 1 ? ARGV[1..-1].join(' ') : nil
refactored_code = OpenAi.new.refactor(code, additional_instructions)

refactored_code += "\n" if refactored_code[-1] != "\n"

if code == refactored_code
  puts "No changes made."
  exit
end

IO.binwrite(file_path, refactored_code)
puts refactored_code
