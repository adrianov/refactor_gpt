#!/usr/bin/env ruby
require 'net/http'
require 'oj'
require 'retries'

# Class to interact with OpenAI API
class OpenAi
  def initialize
    @api_base_url = fetch_env_variable('OPENAI_BASE_URL')
    @api_key = fetch_env_variable('OPENAI_ACCESS_TOKEN')
    @model = 'gpt-4o'
    @temperature = 0
  end

  # Method to send prompts to OpenAI API and get a response
  def ask(prompts)
    with_retries(base_sleep_seconds: 5, max_sleep_seconds: 5, rescue: [Net::ReadTimeout]) do
      uri = URI(@api_base_url + '/chat/completions')
      request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json', 'Authorization' => "Bearer #{@api_key}")
      request.body = Oj.dump({ model: @model, temperature: @temperature, messages: prompts, response_format: { type: 'json_object' } }, mode: :compat, symbol_keys: true)
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 100) { |http| http.request(request) }
      parse_response(response)
    end
  end

  # Method to parse the response and handle errors
  def parse_response(response)
    response_body = response&.body.to_s
    answer = Oj.load(response_body).dig('choices', 0, 'message', 'content') rescue {}
    return answer unless answer.nil? || answer.empty?

    puts response_body
    exit
  end

  # Method to refactor code using OpenAI
  def refactor(code, additional_instructions = nil)
    response = ask([{
      role: 'system',
      content: "Refactor software code. Return complete code block only in JSON {\"code\": \"...\"}."
    }, {
      role: 'user',
      content: <<~HEREDOC
        Refactor the following software code according to these guidelines:

        1. Error Handling: Identify and fix any errors by rewriting the affected sections if necessary.
        2. Descriptive Naming: Use clear and descriptive variable names.
        3. Function Length: Ensure all functions are shorter than 15 lines.
        4. Inline Variables: If a variable used only once, replace it with its value.
        5. Simplify Logic: Reduce the number of assignments, branches, and conditions.
        6. Comments: Add a brief comment before each class or function to explain its purpose.
        7. Preserve Logic: Maintain all existing business logic.

        Return the complete refactored code block only without explanations.

        #{additional_instructions ? 'Additional user instructions: ' + additional_instructions + '.' : ''}

        ```
        #{code}
        ```
      HEREDOC
    }])
    Oj.load(response)['code']
  end

  private

  # Method to fetch environment variables from .env file
  def fetch_env_variable(key, default = nil)
    env_file = File.join(File.dirname(__FILE__), '.env')
    return default unless File.exist?(env_file)

    File.foreach(env_file) do |line|
      return line.split('=')[1].strip if line.start_with?(key)
    end
    default
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

IO.binwrite(file_path, refactored_code)
puts refactored_code
