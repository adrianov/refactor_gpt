#!/usr/bin/env ruby
# frozen_string_literal: true

require 'httpx'
require 'oj'
require 'ruby-progressbar'

# Unified OpenAI client with proxy support for all GPT utilities
class OpenAiClient
  DEFAULT_MODEL = 'glm-4.6'
  REQUEST_TIMEOUT = 300
  PROGRESS_SPEED_FILE = File.join(Dir.home, '.refactor_gpt').freeze

  def initialize(model: nil, debug: false, max_completion_tokens: nil, progress_title: nil)
    @api_base_url = fetch_env('OPENAI_BASE_URL', 'https://api.openai.com/v1')
    @api_key = fetch_env('OPENAI_ACCESS_TOKEN')
    @proxy_url = fetch_env('PROXY_URL', nil)
    @model = model || fetch_env('DEFAULT_MODEL', DEFAULT_MODEL)
    @debug = debug
    @max_completion_tokens = max_completion_tokens
    @progress_title = progress_title
    @env_vars = nil
    @request_timeout = Integer(fetch_env('REQUEST_TIMEOUT', REQUEST_TIMEOUT))
  end

  def ask(messages)
    return ask_with_progress(messages) if @progress_title

    body = build_request_body(messages)
    debug_request(body) if @debug

    response = make_api_request(body)
    handle_response_errors(response)
    extract_answer(response)
  rescue HTTPX::Error => e
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
    http = HTTPX.plugin(:proxy).with(
      timeout: { total_timeout: @request_timeout },
      ssl: { verify_mode: OpenSSL::SSL::VERIFY_NONE }
    )

    # Set up proxy if configured
    http = http.with_proxy(uri: @proxy_url) if @proxy_url && !@proxy_url.empty?

    http.post("#{@api_base_url}/chat/completions",
              headers: {
                'Content-Type' => 'application/json',
                'Authorization' => "Bearer #{@api_key}"
              },
              body: Oj.dump(body, mode: :compat))
  end

  def handle_response_errors(response)
    return if response.status == 200

    warn "OpenAI API request failed with status #{response.status}"
    warn response.body
    exit 1
  rescue NoMethodError
    # Handle HTTPX::ErrorResponse which doesn't have status method
    warn "OpenAI API request failed: #{response.class}"
    warn "Error details: #{response.inspect}"
    exit 1
  end

  def extract_answer(response)
    answer = Oj.load(response.body).dig('choices', 0, 'message', 'content')

    # If content is empty or nil, try reasoning_content
    answer = Oj.load(response.body).dig('choices', 0, 'message', 'reasoning_content') if answer.nil? || answer.empty?

    return answer unless answer.nil? || answer.empty?

    warn 'No answer returned from OpenAI API. Full response body:'
    warn response.body
    exit 1
  end

  def fetch_env(key, default = nil)
    @env_vars ||= load_env_vars
    value = @env_vars.fetch(key, ENV[key] || default)
    return value unless value.nil?

    # Only require certain variables, make others optional
    required_vars = ['OPENAI_ACCESS_TOKEN']
    if required_vars.include?(key)
      warn("Missing required environment variable: #{key}. Please add it to the .env file.")
      exit 1
    end
    default
  end

  def ask_with_progress(messages)
    total_size = [messages.to_s.bytesize, 6000].max
    progress_speed = load_progress_speed

    # Calculate estimated time based on historical speed
    progress_speed.positive? ? total_size / progress_speed : 30

    progressbar = ProgressBar.create(
      title: @progress_title,
      total: total_size,
      format: '%t: |%B| %p%% %e',
      length: 60
    )

    start_time = Time.now
    progress_thread = Thread.new do
      loop do
        elapsed_time = Time.now - start_time
        progress = (elapsed_time * progress_speed).round

        # Allow progress to continue beyond 100%
        if progress <= progressbar.total
          progressbar.progress = progress
        else
          # Increase total so current progress shows as 75%
          progressbar.total = (progress / 0.75).to_i
        end

        sleep 0.1
      end
    end

    begin
      body = build_request_body(messages)
      debug_request(body) if @debug

      response = make_api_request(body)
      handle_response_errors(response)
      answer = extract_answer(response)
    ensure
      progress_thread.kill
      progressbar.finish

      # Save speed for next time
      elapsed_time = Time.now - start_time
      save_progress_speed((load_progress_speed + (total_size / elapsed_time)) / 2.0) if elapsed_time.positive?
    end

    answer
  rescue HTTPX::Error => e
    warn "HTTP request failed: #{e.class} - #{e.message}"
    exit 1
  rescue Oj::ParseError => e
    warn "Failed to parse JSON response: #{e.message}"
    warn response.body if defined?(response) && response&.body
    exit 1
  end

  def load_progress_speed
    return 300 unless File.exist?(PROGRESS_SPEED_FILE)

    value = File.read(PROGRESS_SPEED_FILE).to_f
    return 300 if value <= 0

    value
  rescue SystemCallError, ArgumentError
    300
  end

  def save_progress_speed(speed)
    File.write(PROGRESS_SPEED_FILE, speed.round(2).to_s)
  rescue SystemCallError
    # ignore persistence errors
  end

  def load_env_vars
    # First try project root (one level up from lib/)
    env_file_path = File.join(File.dirname(__dir__), '.env')

    # Fallback to current directory if not found
    env_file_path = File.join(Dir.pwd, '.env') unless File.exist?(env_file_path)

    return {} unless File.exist?(env_file_path)

    File.foreach(env_file_path).with_object({}) do |line, h|
      key, value = line.split('=', 2)
      h[key.strip] = value.strip if key && value
    end
  end
end
