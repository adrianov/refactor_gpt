#!/usr/bin/env ruby
require 'excon'
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
    response = Excon.post(
      "#{@api_base_url}/chat/completions",
      headers: {
        'Content-Type' => 'application/json',
        'Authorization' => "Bearer #{@api_key}"
      },
      body: Oj.dump({ model: @model, temperature: @temperature, messages: prompts }, mode: :compat),
      read_timeout: 100
    )
    answer = Oj.load(response.body).dig('choices', 0, 'message', 'content')
    handle_missing_answer(response) if answer.nil? || answer.empty?
    answer
  end

  # Method to refactor code based on user instructions
  def bash_command(user_instruction)
    system_info = read_system_info
    current_directory = Dir.pwd

    system_instruction = <<~HEREDOC
      Generate a bash command to accomplish the user's request.
      Return the command only.

      System info:
      #{system_info}

      Current directory:
      #{current_directory}

      Directory listing:
      #{Dir.entries(current_directory)}
    HEREDOC

    ask([{ role: 'system', content: system_instruction }, 
         { role: 'user', content: user_instruction }])
      .gsub(/^```.*\n?/, '')
  end

  private

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

  # Method to read system information
  def read_system_info
    File.exist?('/etc/os-release') ? File.read('/etc/os-release') : ''
  end
end

if ARGV.empty?
  puts "Usage: #{File.basename($PROGRAM_NAME)} \"What to do\""
  exit
end

user_instruction = ARGV.join(' ')
bash_command = OpenAi.new.bash_command(user_instruction)

safe_commands = %w[grep ag ls df cat less head tail sed awk tr uniq wc cut]

puts "Generated bash command:\n#{bash_command}"
if safe_commands.any? { |cmd| bash_command.start_with?(cmd + ' ') || bash_command == cmd }
  system(bash_command)
else
  puts "Do you want to run this command? (y/n)"
  answer = STDIN.gets.chomp.downcase

  if answer == 'y'
    system(bash_command)
  else
    puts "Command not executed."
  end
end
