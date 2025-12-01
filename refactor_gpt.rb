#!/usr/bin/env ruby
require 'excon'
require 'oj'
require 'shellwords'
require 'thread'
require 'ruby-progressbar'

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

  # Method to refactor code based on user instructions
  def refactor(code, user_instruction = nil)
    system_instruction = <<~HEREDOC
      Return the complete refactored code module only. Strictly preserve existing
      comments unless implemented TODOs or changed code fragment business logic,
      if not asked otherwise.
    HEREDOC
    default_user_instruction = <<~HEREDOC
      You are refactoring the following code. Apply these rules unless the user
      explicitly overrides them:

      1. Correctness & Robustness
         - Identify and fix bugs or obvious mistakes.
         - Improve error handling where it is clearly insufficient or unsafe.
         - Prefer failing fast with clear messages over silent failures.

      2. Readability & Naming
         - Use clear, descriptive names for variables, methods, and classes.
         - Avoid unnecessary abbreviations unless they are domain-standard.

      3. Structure & Size
         - Prefer small, focused methods.
         - Where it improves clarity, extract helper methods instead of enforcing
           an arbitrary line limit.
         - Keep lines reasonably short (aim for <= 100 characters), but do not
           harm readability just to satisfy a strict width.

      4. Simplicity
         - Simplify complex conditionals and branching where possible.
         - Remove dead code and unnecessary indirection.
         - Inline variables that are used only once when it improves clarity.

      5. Style & Consistency
         - Follow idiomatic Ruby style (Ruby community conventions).
         - Keep formatting consistent with the surrounding code.

      6. Comments & Documentation
         - Preserve all existing comments verbatim unless they refer to code you
           significantly change or a TODO you implement.
         - Do not add new comments unless the user explicitly asks for them.

      7. Behavior Preservation
         - Preserve existing business logic and external behavior unless there is
           a clear bug or the user explicitly requests a change.
         - When you must change behavior to fix a bug, keep the change as small
           and local as possible.

      8. TODOs
         - Implement TODOs only if they are fully specified and safe to complete
           without guessing about missing requirements.
         - If a TODO is ambiguous, leave it in place and do not invent behavior.

      9. Default Behavior
         - Do not change code behavior unless the user specifically asks for it
           or a change is required to fix a clear bug.
    HEREDOC

    prompt = (user_instruction || default_user_instruction) +
             "\n```\n#{code}\n```"
    ask(
      [
        { role: 'system', content: system_instruction },
        { role: 'user', content: prompt }
      ]
    ).gsub(/^```.*\n?/, '')
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
    "Usage: #{File.basename($PROGRAM_NAME)} <file_to_refactor.rb> " \
    '["Instructions what to do."]'
  )
  exit 1
end

file_path = ARGV[0]
unless File.exist?(file_path)
  puts "File not found: #{file_path}"
  exit 1
end

begin
  original_code = File.binread(file_path).force_encoding('UTF-8')
rescue SystemCallError => e
  warn "Failed to read file #{file_path}: #{e.message}"
  exit 1
end

user_instruction = ARGV[1..].join(' ') if ARGV.length > 1
start_time = Time.now

# Progress speed in characters per second
PROGRESS_SPEED = 300

# Initialize progress bar
progressbar = ProgressBar.create(
  title: 'Refactoring',
  total: original_code.size,
  format: '%t: |%B| %p%% %e',
  length: 60
)

# Start progress bar in a separate thread
progress_thread = Thread.new do
  loop do
    elapsed_time = Time.now - start_time
    progress = [(elapsed_time * PROGRESS_SPEED).round, original_code.size].min
    progressbar.progress = progress
    break if progress >= original_code.size

    sleep 0.1
  end
end

refactored_code = OpenAi.new.refactor(original_code, user_instruction)
end_time = Time.now

# Stop progress bar thread
progressbar.finish
progress_thread.join

refactored_code += "\n" if refactored_code[-1] != "\n"

code_size = refactored_code.size
elapsed_time = end_time - start_time
speed = code_size / elapsed_time

puts "\nCode size: #{code_size} characters"
puts "Elapsed time: #{elapsed_time.round(2)} seconds"
puts "Speed: #{speed.round(2)} characters per second"

if original_code == refactored_code
  puts 'No changes made.'
  exit 0
end

is_git_repository = system(
  "git ls-files --error-unmatch " \
  "#{Shellwords.shellescape(file_path)} > #{File::NULL} 2>&1"
)

backup_file_path = "#{file_path}.bak"
unless is_git_repository
  begin
    File.binwrite(backup_file_path, original_code)
  rescue SystemCallError => e
    warn "Failed to write backup file #{backup_file_path}: #{e.message}"
    exit 1
  end
end

begin
  File.binwrite(file_path, refactored_code)
rescue SystemCallError => e
  warn "Failed to write refactored file #{file_path}: #{e.message}"
  exit 1
end

if is_git_repository
  system(
    "git diff -w #{Shellwords.shellescape(file_path)}"
  )
else
  system(
    "diff -u --color #{Shellwords.shellescape(backup_file_path)} " \
    "#{Shellwords.shellescape(file_path)}"
  )
end
