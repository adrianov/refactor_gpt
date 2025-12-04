#!/usr/bin/env ruby
require 'excon'
require 'oj'
require 'ruby-progressbar'
require 'rbconfig'

# Class to interact with OpenAI API
class OpenAi
  def initialize(model: 'gpt-5.1')
    @api_base_url = fetch_env('OPENAI_BASE_URL')
    @api_key = fetch_env('OPENAI_ACCESS_TOKEN')
    @model = model
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

  def chat(question, system_info: nil)
    system_instruction = <<~HEREDOC
      You are a Ruby-focused assistant helping a Ruby programmer.

      Style and format:
      - Answer in clear, concise terms, prioritizing Ruby concepts and tooling.
      - Prefer idiomatic Ruby style in all code examples.
      - Use Markdown formatting (headings, lists, fenced code blocks) where helpful.
      - Default code fences to Ruby unless another language is clearly required.

      Answer length:
      - Be succinct and avoid unnecessary theory.
      - Include just enough detail and examples to make the solution directly usable.

      Code and explanations:
      - When showing code, make it copy-pastable and minimal.
      - Briefly explain non-obvious parts of the code.
      - If there are multiple reasonable approaches, mention the most common one first.

      Translations:
      - When the user asks for word translations (in any language), also:
        - Provide phonetic transcription (IPA if possible).
        - Briefly mention the word origin/etymology.

      Ruby gems:
      - When you recommend Ruby gems, always include a GitHub repository URL for each gem
        you mention, in the form: `gem_name – https://github.com/owner/repo`
        whenever such a public repository is known or can be reasonably inferred.
    HEREDOC

    if system_info && !system_info.empty?
      system_instruction = [
        system_instruction.strip,
        '',
        "User environment:",
        system_info
      ].join("\n")
    end

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

def detect_desktop_environment
  return ENV['XDG_CURRENT_DESKTOP'] if ENV['XDG_CURRENT_DESKTOP'] && !ENV['XDG_CURRENT_DESKTOP'].empty?
  return ENV['DESKTOP_SESSION'] if ENV['DESKTOP_SESSION'] && !ENV['DESKTOP_SESSION'].empty?

  if ENV['GNOME_DESKTOP_SESSION_ID']
    'GNOME'
  elsif ENV['KDE_FULL_SESSION'] == 'true'
    'KDE'
  else
    ''
  end
end

def detect_system_info
  host_os = RbConfig::CONFIG['host_os'].downcase
  platform =
    case host_os
    when /darwin/
      'macOS'
    when /linux/
      if File.exist?('/etc/os-release')
        os_release = File.read('/etc/os-release')
        if os_release =~ /^NAME="?Ubuntu"?/i
          'Ubuntu'
        else
          'Linux'
        end
      else
        'Linux'
      end
    when /mswin|mingw|cygwin/
      'Windows'
    else
      host_os
    end

  version =
    case platform
    when 'macOS'
      `sw_vers -productVersion 2>/dev/null`.strip
    when 'Ubuntu'
      if File.exist?('/etc/os-release')
        os_release = File.read('/etc/os-release')
        if os_release =~ /^VERSION="?([^"\n]+)"?/
          Regexp.last_match(1).strip
        else
          ''
        end
      else
        ''
      end
    when 'Windows'
      `wmic os get Version /value 2>NUL`.split('=').last.to_s.strip
    else
      ''
    end

  parts = []
  parts << "OS: #{platform}"
  parts << "Version: #{version}" unless version.empty?

  desktop_env = detect_desktop_environment
  parts << "Desktop: #{desktop_env}" unless desktop_env.empty?

  parts.join(', ')
rescue StandardError
  ''
end

base_dir = Dir.pwd
question_parts = []
file_snippets = []
total_size = 0
search_mode = false

ARGV.each do |arg|
  if arg == '--search'
    search_mode = true
    next
  end

  path = File.expand_path(arg, base_dir)
  if File.file?(path) && path.start_with?(base_dir + File::SEPARATOR)
    rel = path.sub(base_dir + File::SEPARATOR, '')
    content = File.read(path)
    file_snippets << "File: #{rel}\n#{content}"
    total_size += content.bytesize
  else
    question_parts << arg
  end
end

if question_parts.empty?
  puts 'Enter your question (finish with EOF / Ctrl-D on a new line):'
  input = $stdin.read
  if input.nil? || input.strip.empty?
    warn 'No question provided. Exiting.'
    exit 1
  end
  question_parts << input.strip
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

total_size = [total_size, 2000].max

start_time = Time.now

PROGRESS_SPEED_FILE = File.join(Dir.home, '.refactor_gpt')

def load_progress_speed(progress_speed_file)
  return 300 unless File.exist?(progress_speed_file)

  value = File.read(progress_speed_file).to_f
  return 300 if value <= 0

  value
rescue SystemCallError, ArgumentError
  300
end

PROGRESS_SPEED = load_progress_speed(PROGRESS_SPEED_FILE)

progressbar = ProgressBar.create(
  title: 'Thinking',
  total: total_size,
  format: '%t: |%B| %p%% %e',
  length: 60
)

progress_thread = Thread.new do
  loop do
    elapsed_time = Time.now - start_time
    progress = [(elapsed_time * PROGRESS_SPEED).round, total_size].min
    progressbar.progress = progress
    break if progress >= total_size || progressbar.finished?

    sleep 0.1
  end
end

model_name = search_mode ? 'gpt-4o-search-preview' : 'gpt-5.1'
system_info = detect_system_info
answer = OpenAi.new(model: model_name).chat(question, system_info: system_info)

progressbar.finish unless progressbar.finished?
progress_thread.join

end_time = Time.now
elapsed_time = end_time - start_time
answer_size = answer.to_s.bytesize
speed = answer_size.positive? && elapsed_time.positive? ? answer_size / elapsed_time : 0

begin
  File.write(PROGRESS_SPEED_FILE, speed.round(2).to_s) if speed.positive?
rescue SystemCallError
  # ignore persistence errors
end

if system('command -v glow >/dev/null 2>&1')
  IO.popen(['glow', '--width', '100', '-'], 'w') do |io|
    answer.each_line do |line|
      io.write(line.sub(/ +$/, ''))
    end
  end
else
  puts answer
end
