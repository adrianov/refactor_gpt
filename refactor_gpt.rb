#!/usr/bin/env ruby
require 'net/http'
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
    uri = URI("#{@api_base_url}/chat/completions")
    response = send_request(uri, prompts)
    parse_response(response)
  end

  # Method to refactor code based on user instructions
  def refactor(code, user_instruction = nil)
    system_instruction = "Return the complete refactored code module only."
    default_user_instruction = <<~HEREDOC
      1. Error Handling: Identify and fix any errors by rewriting the affected sections if necessary.
      2. Descriptive Naming: Use clear and descriptive variable names.
      3. Function Length: Ensure all functions are shorter than 15 lines, and all lines are not longer than 80 characters.
      4. Inline Variables: If a variable used only once, replace it with its value.
      5. Simplify Logic: Reduce the number of assignments, branches, and conditions.
      6. Comments: Save existing comments as is. Add a brief comment before each class or function to explain its purpose.
      7. Preserve Logic: Maintain all existing business logic.
      8. Complete TODO
    HEREDOC

    code = (user_instruction || default_user_instruction) + "\n```\n#{code}\n```"
    ask([{ role: 'system', content: system_instruction }, { role: 'user', content: code }])
      .gsub(/^```.*\n?/, '')
  end

  private

  # Method to send the HTTP request
  def send_request(uri, prompts)
    request = Net::HTTP::Post.new(uri, 
      'Content-Type' => 'application/json', 
      'Authorization' => "Bearer #{@api_key}").tap do |req|
        req.body = Oj.dump({ model: @model, temperature: @temperature, messages: prompts }, 
                            mode: :compat, symbol_keys: true)
    end

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

if ARGV.empty?
  puts "Usage: #{File.basename($PROGRAM_NAME)} <file_to_refactor.rb> [\"Instructions what to do.\"]"
  exit
end

file_path = ARGV[0]
unless File.exist?(file_path)
  puts "File not found: #{file_path}"
  exit
end

code = File.binread(file_path)
user_instruction = ARGV[1..-1].join(' ') if ARGV.length > 1
refactored_code = OpenAi.new.refactor(code, user_instruction)
refactored_code += "\n" if refactored_code[-1] != "\n"

if code == refactored_code
  puts "No changes made."
  exit
end

is_git_repository = system("git ls-files --error-unmatch #{Shellwords.shellescape(file_path)} > #{File::NULL} 2>&1")

backup_file_path = "#{file_path}.bak"
File.binwrite(backup_file_path, code) unless is_git_repository
File.binwrite(file_path, refactored_code)

if is_git_repository
  system("git diff #{Shellwords.shellescape(file_path)}")
else
  system("diff -u --color #{Shellwords.shellescape(backup_file_path)} #{Shellwords.shellescape(file_path)}")
end
