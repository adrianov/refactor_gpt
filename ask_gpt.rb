#!/usr/bin/env ruby
# frozen_string_literal: true

require 'excon'
require 'oj'
require 'ruby-progressbar'
require 'rbconfig'

# System information detection
class SystemInfo
  PLATFORM_PATTERNS = { /darwin/ => 'macOS', /linux/ => 'Linux', /mswin|mingw|cygwin/ => 'Windows' }.freeze

  def self.to_s
    @to_s ||= begin
      os = RbConfig::CONFIG['host_os'].downcase
      platform = detect_platform(os)
      version = detect_version(platform)
      desktop = detect_desktop
      format_info(platform, version, desktop)
    rescue StandardError
      ''
    end
  end

  def self.detect_platform(os)
    PLATFORM_PATTERNS.find { |p, _| os.match?(p) }&.last ||
      if os.match?(/linux/)
        if File.exist?('/etc/os-release') && File.read('/etc/os-release') =~ /^NAME="?Ubuntu"?/i
          'Ubuntu'
        else
          'Linux'
        end
      else
        RbConfig::CONFIG['host_os']
      end
  end

  def self.detect_version(platform)
    case platform
    when 'macOS' then `sw_vers -productVersion 2>/dev/null`.strip
    when 'Ubuntu'
      return '' unless File.exist?('/etc/os-release')

      File.read('/etc/os-release').match(/^VERSION="?([^"\n]+)"?/)&.[](1)&.strip || ''
    when 'Windows' then `wmic os get Version /value 2>NUL`.split('=').last.to_s.strip
    else ''
    end
  end

  def self.detect_desktop
    return ENV['XDG_CURRENT_DESKTOP'].to_s unless ENV['XDG_CURRENT_DESKTOP'].to_s.empty?
    return ENV['DESKTOP_SESSION'].to_s unless ENV['DESKTOP_SESSION'].to_s.empty?
    return 'GNOME' if ENV['GNOME_DESKTOP_SESSION_ID']
    return 'KDE' if ENV['KDE_FULL_SESSION'] == 'true'

    ''
  end

  def self.format_info(platform, version, desktop)
    info = "OS: #{platform}"
    info += ", Version: #{version}" unless version.empty?
    info += ", Desktop: #{desktop}" unless desktop.empty?
    info
  end
end

# Argument parsing and utilities
module Utility
  FLAG_MAPPING = { '--search' => :search_mode, '--eldritch' => :eldritch_mode, '--short' => :short_mode,
                   '--debug' => :debug_mode }.freeze

  def self.parse_args(base_dir)
    options = init_options
    question_parts = []
    file_snippets = []

    ARGV.each do |arg|
      if FLAG_MAPPING.key?(arg)
        options[FLAG_MAPPING[arg]] = true
      else
        path = File.expand_path(arg, base_dir)
        if File.file?(path) && path.start_with?(base_dir + File::SEPARATOR)
          file_snippets << "File: #{path.sub(base_dir + File::SEPARATOR, '')}\n#{File.read(path)}"
        else
          question_parts << arg
        end
      end
    end

    question_parts = read_stdin_question if question_parts.empty?
    options.merge(question_parts: question_parts, file_snippets: file_snippets)
  end

  def self.build_question(parts, snippets)
    return parts.join(' ') if snippets.empty?

    [parts.join(' '), '', 'Included files:', snippets.join("\n\n---\n\n")].join("\n")
  end

  def self.total_size(snippets)
    [snippets.sum(&:bytesize), 2000].max
  end

  def self.display_answer(answer)
    return puts answer unless system('command -v glow >/dev/null 2>&1')

    urls = answer.scan(%r{\[.*?\]\(https?://[^)]+\)|https?://[^\s)]+})
    width = urls.empty? ? '100' : [urls.map(&:length).max + 2, 100].max.to_s
    formatted = answer.gsub(%r{\(\s*\n\s*(https?://[^)]+)\)}, '(\\1)').gsub(%r{(\[.*?\]\(https?://[^)]+\))}, "\n\n\\1")

    IO.popen(['glow', '--width', width, '-'], 'w') { |io| formatted.each_line { |l| io.write(l.sub(/ +$/, '')) } }
  end

  def self.init_options
    FLAG_MAPPING.values.map { |k| [k, false] }.to_h
  end

  def self.read_stdin_question
    puts 'Enter your question (finish with EOF / Ctrl-D on a new line):'
    input = $stdin.read
    if input.nil? || input.strip.empty?
      warn 'No question provided. Exiting.'
      exit 1
    end
    [input.strip]
  end
end

# Progress bar management
class ProgressManager
  PROGRESS_SPEED_FILE = File.join(Dir.home, '.refactor_gpt').freeze
  DEFAULT_SPEED = 300

  def initialize(total_size)
    @total_size = total_size
    @start_time = Time.now
    @progress_speed = load_speed
  end

  def start
    @progressbar = ProgressBar.create(title: 'Thinking', total: @total_size, format: '%t: |%B| %p%% %e', length: 60)
    @progress_thread = Thread.new { update_progress }
  end

  def finish
    @progressbar.finish unless @progressbar.finished?
    @progress_thread.join
  end

  def save_speed(answer_size, elapsed_time)
    speed = calculate_speed(answer_size, elapsed_time)
    File.write(PROGRESS_SPEED_FILE, speed.round(2).to_s) if speed.positive?
  rescue SystemCallError
  end

  private

  def load_speed
    File.exist?(PROGRESS_SPEED_FILE) ? File.read(PROGRESS_SPEED_FILE).to_f : DEFAULT_SPEED
  end

  def update_progress
    loop do
      progress = [(Time.now - @start_time) * @progress_speed, @total_size].min.round
      @progressbar.progress = progress
      break if progress >= @total_size || @progressbar.finished?

      sleep 0.1
    end
  end

  def calculate_speed(answer_size, elapsed_time)
    return 0 unless answer_size.positive? && elapsed_time.positive?

    answer_size / elapsed_time
  end
end

# OpenAI API client
class OpenAiClient
  DEFAULT_MODEL = 'gpt-5.1'

  def initialize(model: DEFAULT_MODEL, max_completion_tokens: nil, debug: false)
    @api_base_url = fetch_env('OPENAI_BASE_URL')
    @api_key = fetch_env('OPENAI_ACCESS_TOKEN')
    @model = model
    @max_completion_tokens = max_completion_tokens
    @debug = debug
    @env_vars = nil
  end

  def chat(question, style: nil, brevity: nil)
    system_instr = build_system_instruction(style, brevity)
    ask([{ role: 'system', content: system_instr }, { role: 'user', content: question }])
  end

  def ask(messages)
    body = build_request_body(messages)
    debug_request(body) if @debug

    response = make_api_request(body)
    handle_response_errors(response)
    extract_answer(response)
  rescue Excon::Error => e
    warn "HTTP request failed: #{e.class} - #{e.message}"
    exit 1
  rescue Oj::ParseError => e
    warn "Failed to parse JSON response: #{e.message}"
    warn response.body if defined?(response) && response&.body
    exit 1
  end

  private

  def build_request_body(messages)
    body = { model: @model, messages: messages }
    body[:max_completion_tokens] = @max_completion_tokens if @max_completion_tokens
    body
  end

  def debug_request(body)
    warn '--- OpenAI request payload (Ruby hash) ---'
    pretty_messages = body[:messages].map do |msg|
      if msg[:role] == 'system' && msg[:content].is_a?(String)
        { role: msg[:role], content_lines: msg[:content].split("\n") }
      else
        msg
      end
    end
    warn Oj.dump(body.merge(messages: pretty_messages), mode: :compat, indent: 2)
    warn '--- end payload ---'
  end

  def make_api_request(body)
    Excon.post(
      "#{@api_base_url}/chat/completions",
      headers: { 'Content-Type' => 'application/json', 'Authorization' => "Bearer #{@api_key}" },
      body: Oj.dump(body, mode: :compat),
      read_timeout: 100
    )
  end

  def handle_response_errors(response)
    return if response.status == 200

    warn "OpenAI API request failed with status #{response.status}"
    warn response.body
    exit 1
  end

  def extract_answer(response)
    answer = Oj.load(response.body).dig('choices', 0, 'message', 'content')
    return answer unless answer.nil? || answer.empty?

    warn 'No answer returned from OpenAI API. Full response body:'
    warn response.body
    exit 1
  end

  def build_system_instruction(style, brevity)
    style_instr = build_style_instruction(style)
    style_instr += build_brevity_instruction if brevity == :short

    system_instr = base_instruction(style_instr)
    system_info = SystemInfo.to_s
    system_info.empty? ? system_instr : [system_instr.strip, '', 'User environment:', system_info].join("\n")
  end

  def build_style_instruction(style)
    return 'Answer in a Lovecraftian, eldritch horror tone' if style == :eldritch

    <<~HEREDOC
      - Answer in clear, concise terms, prioritizing Ruby concepts and tooling.
      - Prefer idiomatic Ruby style in all code examples.
      - Use Markdown formatting (headings, lists, fenced code blocks) where helpful.
      - Default code fences to Ruby unless another language is clearly required.
      - Always respond using Markdown formatting, even for very short answers.
    HEREDOC
  end

  def build_brevity_instruction
    <<~HEREDOC
      Answer in 1–2 short, direct phrases; be as brief as possible while still being correct and useful.
      Avoid lists, headings, or multi-sentence paragraphs unless absolutely necessary.
      If a one-word answer would be fully correct and sufficient, answer with that single word.
    HEREDOC
  end

  def base_instruction(style_instr)
    <<~HEREDOC
      You are a Ruby-focused assistant helping a Ruby programmer.

      Style and format:
      #{style_instr}

      Answer length:
      - Be succinct and avoid unnecessary theory.
      - Include just enough detail and examples to make solution directly usable.
      - If user asks a short, direct question and does not explicitly request detail,
        respond with a short, direct answer (1–3 short sentences or bullet points) by default.
      - If the user's question can be fully answered with a single word (e.g., "yes", "no", a name, a number),
        respond with exactly that one word unless they explicitly ask for explanation.

      Code and explanations:
      - When showing code, make it copy-pastable and minimal.
      - Briefly explain non-obvious parts of the code.
      - If there are multiple reasonable approaches, mention the most common one first.

      Translations:
      - Provide translations to Russian, English, French, German, Spanish, and Italian
      - Follow user-specified language pairs when provided
      - For short phrases: include translation, phonetics, and brief etymology when relevant

      Ruby gems:
      - When you recommend Ruby gems, always include a GitHub repository URL for each gem
        you mention, in form: `gem_name – https://github.com/owner/repo`
        whenever such a public repository is known or can be reasonably inferred.
    HEREDOC
  end

  def fetch_env(key, default = nil)
    @env_vars ||= load_env_vars
    value = @env_vars.fetch(key, ENV[key] || default)
    return value unless value.nil?

    warn("Missing required environment variable: #{key}. Please add it to the .env file.")
    exit 1
  end

  def load_env_vars
    env_file_path = File.join(File.dirname(__FILE__), '.env')
    return {} unless File.exist?(env_file_path)

    File.foreach(env_file_path).with_object({}) do |line, h|
      k, v = line.split('=', 2)
      h[k.strip] = v.strip if k && v
    end
  end
end

# Main application
def main
  args = Utility.parse_args(Dir.pwd)
  progress = ProgressManager.new(Utility.total_size(args[:file_snippets]))
  progress.start

  start_time = Time.now
  answer = OpenAiClient.new(
    model: args[:search_mode] ? 'gpt-4o-search-preview' : 'gpt-5.1',
    max_completion_tokens: args[:short_mode] ? 500 : nil,
    debug: args[:debug_mode]
  ).chat(
    Utility.build_question(args[:question_parts], args[:file_snippets]),
    style: args[:eldritch_mode] ? :eldritch : nil,
    brevity: args[:short_mode] ? :short : nil
  )

  progress.finish
  progress.save_speed(answer.to_s.bytesize, Time.now - start_time)
  Utility.display_answer(answer)
end

main if __FILE__ == $PROGRAM_NAME
