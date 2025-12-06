#!/usr/bin/env ruby
require 'excon'
require 'oj'
require 'ruby-progressbar'
require 'rbconfig'

# Simple system information detection with memoization
class SystemInfo
  def self.to_s
    @system_info ||= begin
      platform = case RbConfig::CONFIG['host_os'].downcase
                 when /darwin/ then 'macOS'
                 when /linux/ then File.exist?('/etc/os-release') && File.read('/etc/os-release') =~ /^NAME="?Ubuntu"?/i ? 'Ubuntu' : 'Linux'
                 when /mswin|mingw|cygwin/ then 'Windows'
                 else RbConfig::CONFIG['host_os']
                 end

      version = case platform
                when 'macOS' then `sw_vers -productVersion 2>/dev/null`.strip
                when 'Ubuntu' then File.exist?('/etc/os-release') && File.read('/etc/os-release') =~ /^VERSION="?([^"\n]+)"?/ ? Regexp.last_match(1).strip : ''
                when 'Windows' then `wmic os get Version /value 2>NUL`.split('=').last.to_s.strip
                else ''
                end

      desktop = if !ENV['XDG_CURRENT_DESKTOP'].to_s.empty?
                  ENV['XDG_CURRENT_DESKTOP'].to_s
                elsif !ENV['DESKTOP_SESSION'].to_s.empty?
                  ENV['DESKTOP_SESSION'].to_s
                elsif ENV['GNOME_DESKTOP_SESSION_ID']
                  'GNOME'
                elsif ENV['KDE_FULL_SESSION'] == 'true'
                  'KDE'
                else
                  ''
                end

      "OS: #{platform}" +
        (version.empty? ? '' : ", Version: #{version}") +
        (desktop.empty? ? '' : ", Desktop: #{desktop}")
    rescue StandardError
      ''
    end
  end
end

# Utility module for common operations
module Utility
  def self.parse_arguments(base_dir)
    question_parts = []
    file_snippets = []
    search_mode = false
    eldritch_mode = false
    short_mode = false
    debug_mode = false

    ARGV.each do |arg|
      case arg
      when '--search' then search_mode = true
                           next
      when '--eldritch' then eldritch_mode = true
                             next
      when '--short' then short_mode = true
                          next
      when '--debug' then debug_mode = true
                          next
      end

      path = File.expand_path(arg, base_dir)
      if File.file?(path) && path.start_with?(base_dir + File::SEPARATOR)
        rel = path.sub(base_dir + File::SEPARATOR, '')
        content = File.read(path)
        file_snippets << "File: #{rel}\n#{content}"
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

    { question_parts: question_parts, file_snippets: file_snippets, search_mode: search_mode,
      eldritch_mode: eldritch_mode, short_mode: short_mode, debug_mode: debug_mode }
  end

  def self.build_question(question_parts, file_snippets)
    return question_parts.join(' ') if file_snippets.empty?

    [question_parts.join(' '), '', 'Included files:', file_snippets.join("\n\n---\n\n")].join("\n")
  end

  def self.calculate_total_size(file_snippets)
    [file_snippets.sum { |snippet| snippet.bytesize }, 2000].max
  end

  def self.display_answer(answer)
    return puts answer unless system('command -v glow >/dev/null 2>&1')

    # Check if answer contains URLs
    has_urls = answer.match?(%r{https?://[^\s]+})
    width = has_urls ? '0' : '100'

    IO.popen(['glow', '--width', width, '-'], 'w') do |io|
      answer.each_line { |line| io.write(line.sub(/ +$/, '')) }
    end
  end
end

# Class to manage progress bar display
class ProgressManager
  PROGRESS_SPEED_FILE = File.join(Dir.home, '.refactor_gpt')
  DEFAULT_PROGRESS_SPEED = 300

  def initialize(total_size)
    @total_size = total_size
    @start_time = Time.now
    @progress_speed = load_progress_speed
  end

  def start
    @progressbar = ProgressBar.create(
      title: 'Thinking',
      total: @total_size,
      format: '%t: |%B| %p%% %e',
      length: 60
    )

    @progress_thread = Thread.new do
      loop do
        elapsed_time = Time.now - @start_time
        progress = [(elapsed_time * @progress_speed).round, @total_size].min
        @progressbar.progress = progress
        break if progress >= @total_size || @progressbar.finished?

        sleep 0.1
      end
    end
  end

  def finish
    @progressbar.finish unless @progressbar.finished?
    @progress_thread.join
  end

  def save_speed(answer_size, elapsed_time)
    speed = answer_size.positive? && elapsed_time.positive? ? answer_size / elapsed_time : 0
    return unless speed.positive?

    File.write(PROGRESS_SPEED_FILE, speed.round(2).to_s)
  rescue SystemCallError
    # ignore persistence errors
  end

  private

  def load_progress_speed
    File.read(PROGRESS_SPEED_FILE).to_f
  rescue StandardError
    DEFAULT_PROGRESS_SPEED
  end
end

# Class to interact with OpenAI API
class OpenAi
  def initialize(model: 'gpt-5.1', max_completion_tokens: nil, debug: false)
    @api_base_url = fetch_env('OPENAI_BASE_URL')
    @api_key = fetch_env('OPENAI_ACCESS_TOKEN')
    @model = model
    @max_completion_tokens = max_completion_tokens
    @debug = debug
  end

  def ask(prompts)
    body_hash = { model: @model, messages: prompts }
    body_hash[:max_completion_tokens] = @max_completion_tokens if @max_completion_tokens

    body_json = Oj.dump(body_hash, mode: :compat)

    if @debug
      warn '--- OpenAI request payload (Ruby hash) ---'
      pretty_messages = body_hash[:messages].map do |msg|
        if msg[:role] == 'system' && msg[:content].is_a?(String)
          { role: msg[:role], content_lines: msg[:content].split("\n") }
        else
          msg
        end
      end
      warn Oj.dump(body_hash.merge(messages: pretty_messages), mode: :compat, indent: 2)
      warn '--- end payload ---'
    end

    response = Excon.post(
      "#{@api_base_url}/chat/completions",
      headers: { 'Content-Type' => 'application/json', 'Authorization' => "Bearer #{@api_key}" },
      body: body_json,
      read_timeout: 100
    )
    handle_http_error(response) unless response.status == 200
    answer = Oj.load(response.body).dig('choices', 0, 'message', 'content')
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

  def chat(question, style: nil, brevity: nil)
    style_instruction = case style
                        when :eldritch then 'Answer in a Lovecraftian, eldritch horror tone'
                        else <<~HEREDOC
                          - Answer in clear, concise terms, prioritizing Ruby concepts and tooling.
                          - Prefer idiomatic Ruby style in all code examples.
                          - Use Markdown formatting (headings, lists, fenced code blocks) where helpful.
                          - Default code fences to Ruby unless another language is clearly required.
                          - Always respond using Markdown formatting, even for very short answers.
                        HEREDOC
                        end

    if brevity == :short
      style_instruction += <<~HEREDOC
        Answer in 1–2 short, direct phrases; be as brief as possible while still being correct and useful.
        Avoid lists, headings, or multi-sentence paragraphs unless absolutely necessary.
        If a one-word answer would be fully correct and sufficient, answer with that single word.
      HEREDOC
    end

    system_info = SystemInfo.to_s
    system_instruction = <<~HEREDOC
      You are a Ruby-focused assistant helping a Ruby programmer.

      Style and format:
      #{style_instruction}

      Answer length:
      - Be succinct and avoid unnecessary theory.
      - Include just enough detail and examples to make the solution directly usable.
      - If the user asks a short, direct question and does not explicitly request detail,
        respond with a short, direct answer (1–3 short sentences or bullet points) by default.
      - If the user's question can be fully answered with a single word (e.g., "yes", "no", a name, a number),
        respond with exactly that one word unless they explicitly ask for explanation.

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

    unless system_info.empty?
      system_instruction = [system_instruction.strip, '', 'User environment:', system_info].join("\n")
    end

    ask([{ role: 'system', content: system_instruction }, { role: 'user', content: question }])
  end

  private

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

    File.foreach(env_file_path).with_object({}) do |line, env_vars|
      key, value = line.split('=', 2)
      next unless key && value

      env_vars[key.strip] = value.strip
    end
  end

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

# Main execution logic
def main
  args = Utility.parse_arguments(Dir.pwd)

  progress_manager = ProgressManager.new(Utility.calculate_total_size(args[:file_snippets]))
  progress_manager.start

  start_time = Time.now
  answer = OpenAi.new(
    model: args[:search_mode] ? 'gpt-4o-search-preview' : 'gpt-5.1',
    max_completion_tokens: args[:short_mode] ? 500 : nil,
    debug: args[:debug_mode]
  ).chat(
    Utility.build_question(args[:question_parts], args[:file_snippets]),
    style: args[:eldritch_mode] ? :eldritch : nil,
    brevity: args[:short_mode] ? :short : nil
  )

  progress_manager.finish
  progress_manager.save_speed(answer.to_s.bytesize, Time.now - start_time)
  Utility.display_answer(answer)
end

main if __FILE__ == $0
