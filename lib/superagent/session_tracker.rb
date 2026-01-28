# frozen_string_literal: true

require 'json'
require 'digest'
require 'fileutils'
require_relative '../../ask_gpt'

# Tracks session information and detects continuation
class SessionTracker
  SESSION_DIR = File.join(Dir.tmpdir, 'refactor_gpt_sessions')
  MAX_SESSION_AGE = 86400 # 24 hours

  def initialize(display)
    @display = display
    ensure_session_dir
  end

  def load_previous_session
    session_file = find_latest_session_file
    return nil unless session_file

    session_data = read_session_file(session_file)
    return nil unless session_data && !session_expired?(session_data)

    session_data
  end

  def classify_request(request)
    client = create_ask_client
    return {tags: []} unless client

    prompt = build_classification_prompt(request)
    response = query_ask_client(client, prompt)
    tags = parse_classification_response(response)
    {tags: tags}
  rescue StandardError => e
    @display.puts "Warning: Failed to classify request: #{e.message}".yellow
    {tags: []}
  end

  def analyze_continuation(new_request, previous_session)
    return {continuation: false, tags: []} unless previous_session

    client = create_ask_client
    return {continuation: false, tags: []} unless client

    prompt = build_continuation_analysis_prompt(new_request, previous_session[:request])
    response = query_ask_client(client, prompt)
    parse_continuation_response(response)
  rescue StandardError => e
    @display.puts "Warning: Failed to analyze continuation: #{e.message}".yellow
    {continuation: false, tags: []}
  end

  def generate_session_description(request, tags = [])
    client = create_ask_client
    return "Session: #{request[0..100]}..." unless client

    prompt = build_description_prompt(request, tags)
    response = query_ask_client(client, prompt)
    extract_description(response) || "Session: #{request[0..100]}..."
  rescue StandardError => e
    @display.puts "Warning: Failed to generate description: #{e.message}".yellow
    "Session: #{request[0..100]}..."
  end

  def save_session(request, description, tags, continuation, last_agent_summary = :not_provided)
    previous_session = load_previous_session
    request_history = build_request_history(continuation, previous_session)
    agent_summary = determine_agent_summary(continuation, previous_session, last_agent_summary)

    session_data = {
      request: request,
      description: description,
      tags: tags,
      continuation: continuation,
      request_history: request_history,
      last_agent_summary: agent_summary,
      timestamp: Time.now.to_i,
      cwd: Dir.pwd
    }

    session_file = session_file_path
    File.write(session_file, JSON.pretty_generate(session_data))
    cleanup_old_sessions
  end

  def build_request_history(continuation, previous_session)
    return [] unless continuation && previous_session && previous_session[:request_history]

    previous_session[:request_history] + [previous_session[:request]]
  end

  def determine_agent_summary(continuation, previous_session, last_agent_summary)
    return last_agent_summary unless last_agent_summary == :not_provided

    return nil unless continuation
    return nil unless previous_session && previous_session[:last_agent_summary]

    previous_session[:last_agent_summary]
  end

  def get_session_request_history
    session_data = load_previous_session
    return [] unless session_data

    history = session_data[:request_history] || []
    previous_request = session_data[:request]
    history + (previous_request ? [previous_request] : [])
  end

  def get_last_agent_summary
    session_data = load_previous_session
    return nil unless session_data

    session_data[:last_agent_summary]
  end

  private

  def ensure_session_dir
    FileUtils.mkdir_p(SESSION_DIR)
  end

  def session_file_path
    cwd_hash = Digest::SHA256.hexdigest(Dir.pwd)
    File.join(SESSION_DIR, "#{cwd_hash}.json")
  end

  def find_latest_session_file
    session_file = session_file_path
    return session_file if File.exist?(session_file)

    nil
  end

  def read_session_file(file_path)
    return nil unless File.exist?(file_path)

    content = File.read(file_path)
    JSON.parse(content, symbolize_names: true)
  rescue JSON::ParserError
    nil
  rescue StandardError
    nil
  end

  def session_expired?(session_data)
    return true unless session_data[:timestamp]

    age = Time.now.to_i - session_data[:timestamp]
    age > MAX_SESSION_AGE
  end

  def create_ask_client
    return AskGeminiClient.new(progress: false) if Utility.gemini_configured?
    return AskGptClient.new if Utility.openai_configured?

    nil
  end

  def build_classification_prompt(request)
    <<~HEREDOC
      Classify the following request by identifying applicable tags.

      Request:
      #{request}

      Identify applicable tags from the following list:
      - #bug: Fixing a defect or error in the code
      - #regression: Fixing a bug that was previously resolved but has been reintroduced
      - #hotfix: Urgent bug fix requiring immediate deployment
      - #feature: Adding new functionality or capabilities
      - #improvement: Enhancing existing functionality without adding new features
      - #refactoring: Restructuring code without changing behavior
      - #performance: Optimizing speed, memory usage, or resource consumption
      - #security: Addressing security vulnerabilities or hardening defenses
      - #test: Writing, updating, or fixing tests
      - #docs: Creating or updating documentation
      - #plan: Planning, designing, or discussing implementation approach
      - #debug: Investigating and diagnosing issues
      - #investigation: Analyzing problems or exploring solutions
      - #chore: Maintenance tasks, dependency updates, or housekeeping
      - #api: Changes to API interfaces or contracts
      - #ui: User interface modifications
      - #ux: User experience improvements
      - #config: Configuration or environment changes
      - #migration: Database or system migration tasks

      Response format (required):
      TAGS: comma-separated tags (e.g., #bug, #improvement) or NONE

      Examples:
      - "fix login error" → TAGS: #bug
      - "login broke again after the update" → TAGS: #regression
      - "add email validation" → TAGS: #feature
      - "optimize database queries" → TAGS: #improvement, #performance
      - "refactor user service" → TAGS: #refactoring
      - "update README with new API endpoints" → TAGS: #docs
      - "plan the authentication system architecture" → TAGS: #plan
      - "investigate why the server is crashing" → TAGS: #investigation, #debug
      - "Write a simple calc app with buttons" → TAGS: #feature, #ui
    HEREDOC
  end

  def build_continuation_analysis_prompt(new_req, previous_req)
    <<~HEREDOC
      Analyze the relationship between two requests and classify the new request.

      Previous request:
      #{previous_req}

      New request:
      #{new_req}

      Tasks:
      1. Determine if the new request continues the previous work (YES) or starts a new session (NO)
      2. Identify applicable tags from the following list:
         - #bug: Fixing a defect or error in the code
         - #regression: Fixing a bug that was previously resolved but has been reintroduced
         - #hotfix: Urgent bug fix requiring immediate deployment
         - #feature: Adding new functionality or capabilities
         - #improvement: Enhancing existing functionality without adding new features
         - #refactoring: Restructuring code without changing behavior
         - #performance: Optimizing speed, memory usage, or resource consumption
         - #security: Addressing security vulnerabilities or hardening defenses
         - #test: Writing, updating, or fixing tests
         - #docs: Creating or updating documentation
         - #plan: Planning, designing, or discussing implementation approach
         - #debug: Investigating and diagnosing issues
         - #investigation: Analyzing problems or exploring solutions
         - #chore: Maintenance tasks, dependency updates, or housekeeping
         - #api: Changes to API interfaces or contracts
         - #ui: User interface modifications
         - #ux: User experience improvements
         - #config: Configuration or environment changes
         - #migration: Database or system migration tasks

      Response format (required):
      CONTINUATION: YES or NO
      TAGS: comma-separated tags (e.g., #bug, #improvement) or NONE

      Examples:
      - "fix login error" → CONTINUATION: NO, TAGS: #bug
      - "login broke again after the update" → CONTINUATION: NO, TAGS: #regression
      - "also add email validation" → CONTINUATION: YES, TAGS: #feature
      - "optimize database queries" → CONTINUATION: NO, TAGS: #improvement, #performance
      - "refactor user service" → CONTINUATION: NO, TAGS: #refactoring
      - "update README with new API endpoints" → CONTINUATION: NO, TAGS: #docs
      - "plan the authentication system architecture" → CONTINUATION: NO, TAGS: #plan
      - "investigate why the server is crashing" → CONTINUATION: NO, TAGS: #investigation, #debug
    HEREDOC
  end

  def build_description_prompt(request, tags)
    tags_text = tags.empty? ? '' : " Tags: #{tags.join(', ')}"
    <<~HEREDOC
      Generate a concise one-sentence description of this session request.

      Request: #{request}#{tags_text}

      Provide only the description, no prefix or formatting. Keep it under 100 characters.
      Examples:
      - "Add user authentication with email validation"
      - "Fix memory leak in data processing module"
      - "Refactor API endpoints for better error handling"
    HEREDOC
  end

  def query_ask_client(client, prompt)
    if client.is_a?(AskGeminiClient)
      client.ask([{role: "user", content: prompt}], title: nil)
    else
      system_msg = "You are a request analyzer. Provide concise, structured responses."
      messages = [
        {role: "system", content: system_msg},
        {role: "user", content: prompt}
      ]
      client.ask(messages, title: nil)
    end
  end

  def parse_classification_response(response)
    return [] unless response

    tags_match = response.match(/TAGS:\s*(.+?)(?:\n|$)/i)
    tags_text = tags_match ? tags_match[1].strip : ""
    extract_tags(tags_text)
  end

  def parse_continuation_response(response)
    return {continuation: false, tags: []} unless response

    continuation_match = response.match(/CONTINUATION:\s*(YES|NO)/i)
    tags_match = response.match(/TAGS:\s*(.+?)(?:\n|$)/i)

    continuation = continuation_match && continuation_match[1].upcase == "YES"
    tags_text = tags_match ? tags_match[1].strip : ""
    tags = extract_tags(tags_text)

    {continuation: continuation, tags: tags}
  end

  def extract_tags(tags_text)
    return [] if tags_text.empty? || tags_text.upcase == "NONE"

    tags_text.split(",").map(&:strip).reject(&:empty?).select { |tag| tag.start_with?("#") }
  end

  def extract_description(response)
    return nil unless response

    description = response.strip
    description = description.gsub(/^(Description:|Session:)\s*/i, '')
    description = description.split("\n").first
    description = description[0..99] if description && description.length > 100
    description&.strip
  end

  def cleanup_old_sessions
    return unless Dir.exist?(SESSION_DIR)

    Dir.glob(File.join(SESSION_DIR, '*.json')).each do |file|
      begin
        session_data = read_session_file(file)
        File.delete(file) if session_data.nil? || session_expired?(session_data)
      rescue StandardError
        # Ignore errors during cleanup
      end
    end
  end
end
