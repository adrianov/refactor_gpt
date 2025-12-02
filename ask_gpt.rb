#!/usr/bin/env ruby
require 'excon'
require 'oj'

# Class to interact with OpenAI API
class OpenAi
  def initialize
    @api_base_url = fetch_env('OPENAI_BASE_URL')
    @api_key = fetch_env('OPENAI_ACCESS_TOKEN')
    @model = 'gpt-5.1'
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
      body: Oj.dump(
        {
          model: @model,
          temperature: @temperature,
          messages: prompts
        },
        mode: :compat
      ),
      read_timeout: 100
    )
    handle_http_error(response) unless response.status == 200
    answer = Oj.load(response.body)
               .dig('choices', 0, 'message', 'content')
    handle_missing_answer(response) if answer.nil? || answer.empty?
    answer
  rescue Excon::Error => e
    warn "HTTP request failed: #{e.class} - #{e.message}"
    exit 1
  rescue Oj::ParseError => e
    warn "Failed to parse JSON response: #{e.message}"
    warn response.body if defined?(response) && response&.body
    exit 1
  end

  def chat(question)
    system_instruction = <<~HEREDOC
      You are helping a Ruby programmer. Answer in clear, concise Ruby-focused
      terms, using idiomatic Ruby style, with code examples where appropriate.
      Keep answers relatively short and not overly detailed.

      When the user asks for word translations (in any language), also:
      - Provide phonetic transcription (IPA if possible).
      - Briefly mention the word origin/etymology.
    HEREDOC

    ask(
      [
        { role: 'system', content: system_instruction },
        { role: 'user', content: question }
      ]
    )
  end

  private

  # Method to fetch environment variables
  def fetch_env(key, default = nil)
    @env_vars ||= load_env_vars
    value = @env_vars.fetch(key, ENV[key] || default)
    return value unless value.nil?

    warn(
      "Missing required environment variable: #{key}. " \
      'Please add it to the .env file.'
    )
    exit 1
  end

  # Method to load environment variables from a file
  def load_env_vars
    env_file_path = File.join(File.dirname(__FILE__), '.env')
    return {} unless File.exist?(env_file_path)

    File.foreach(env_file_path).with_object({}) do |line, env_vars|
      key, value = line.split('=')
      next unless key && value

      env_vars[key.strip] = value.strip
    end
  end

  # Method to handle missing answers in the response
  def handle_missing_answer(response)
    warn 'No answer returned from OpenAI API. Full response body:'
    warn response.body
    exit 1
  end

  def handle_http_error(response)
    warn "OpenAI API request failed with status #{response.status}"
    warn response.body
    exit 1
  end
end

if ARGV.empty?
  puts(
    "Usage: #{File.basename($PROGRAM_NAME)} \"Your question about Ruby or code\""
  )
  exit 1
end

base_dir = Dir.pwd
question_parts = []
file_snippets = []

ARGV.each do |arg|
  path = File.expand_path(arg, base_dir)
  if File.file?(path) && path.start_with?(base_dir + File::SEPARATOR)
    rel = path.sub(base_dir + File::SEPARATOR, '')
    content = File.read(path)
    file_snippets << "File: #{rel}\n#{content}"
  else
    question_parts << arg
  end
end

question = question_parts.join(' ')
unless file_snippets.empty?
  question = [
    question,
    '',
    'Included files:',
    file_snippets.join("\n\n---\n\n")
  ].join("\n")
end

answer = OpenAi.new.chat(question)
puts answer
