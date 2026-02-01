# frozen_string_literal: true

require 'oj'
require 'digest'
require 'fileutils'

# Tracks session information and detects continuation
class SessionTracker
  SESSION_DIR = ConfigPath::CONFIG_DIR
  MAX_SESSION_AGE = 86400 # 24 hours

  TAGS_LIST = <<~TAGS.strip
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
  TAGS

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

  def analyze_continuation_and_description(new_request, previous_session)
    client = create_ask_client
    default = {continuation: false, tags: [], description: default_description(new_request)}
    return default unless client

    prompt, title = continuation_prompt_and_title(new_request, previous_session)
    run_continuation_query(client, prompt, title, new_request, previous_session)
  rescue StandardError => e
    @display.puts "Warning: Failed to analyze: #{e.message}".yellow
    default
  end

  def run_continuation_query(client, prompt, title, new_request, previous_session)
    response = query_ask_client(client, prompt, title: title)
    @display.puts response.light_black if response && !response.to_s.strip.empty?
    result = parse_continuation_and_description_response(response, previous_session)
    result[:description] = description_or_default(result[:description], new_request)
    result
  end

  def continuation_prompt_and_title(new_request, previous_session)
    prompt = build_analysis_and_description_prompt(new_request, previous_session)
    title = previous_session ? "Analyzing continuation" : "Classifying request"
    [prompt, title]
  end

  def default_description(request)
    "Session: #{request[0..100]}..."
  end

  def description_or_default(description, request)
    description.to_s.strip.empty? ? default_description(request) : description
  end

  DEFAULT_REQUEST_TYPE = 'implementation'

  def save_session(request, description, tags, continuation, last_agent_summary = :not_provided,
                   request_type: DEFAULT_REQUEST_TYPE)
    previous_session = load_previous_session
    prev_list = previous_request_history_list(previous_session)
    new_entries = expand_combined(request, type: request_type)
    request_history = last_entry_matches?(prev_list, new_entries) ? prev_list : prev_list + new_entries
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
    File.write(session_file, Oj.dump(session_data, mode: :compat, indent: 2))
    cleanup_old_sessions
  end

  def determine_agent_summary(_continuation, previous_session, last_agent_summary)
    return last_agent_summary unless last_agent_summary == :not_provided
    return nil unless previous_session && previous_session[:last_agent_summary]

    previous_session[:last_agent_summary]
  end

  # Appends a request to session request_history so queue-added requests appear in "Previous requests".
  def append_to_request_history(request, type: DEFAULT_REQUEST_TYPE)
    return if request.nil? || request.to_s.strip.empty?

    previous = load_previous_session
    prev_list = previous_request_history_list(previous)
    new_entries = expand_combined(request, type: type)
    return if new_entries.size == 1 && last_entry_matches?(prev_list, new_entries)

    write_append_session(previous, prev_list, new_entries)
  end

  def write_append_session(previous, prev_list, new_entries)
    session_data = (previous || {}).merge(
      request_history: prev_list + new_entries,
      timestamp: Time.now.to_i,
      cwd: Dir.pwd
    )
    File.write(session_file_path, Oj.dump(session_data, mode: :compat, indent: 2))
  end

  def get_session_request_history(exclude_equal: nil)
    session_data = load_previous_session
    return [] unless session_data

    list = previous_request_history_list(session_data)
    return list if exclude_equal.nil? || exclude_equal.to_s.strip.empty?

    exclude = exclude_equal.to_s.strip
    list.reject { |req| req[:text].to_s.strip == exclude }
  end

  def get_last_agent_summary
    session_data = load_previous_session
    return nil unless session_data

    session_data[:last_agent_summary]
  end

  private

  def previous_request_history_list(session)
    (session&.dig(:request_history) || []).map { |el| normalize_request_entry(el) }
  end

  def normalize_request_entry(el)
    return { type: DEFAULT_REQUEST_TYPE, text: el.to_s } unless el.is_a?(Hash)

    {
      type: (el[:type] || el['type'] || DEFAULT_REQUEST_TYPE).to_s,
      text: (el[:text] || el['text'] || el.to_s).to_s
    }
  end

  def expand_combined(request, type: DEFAULT_REQUEST_TYPE)
    return [] if request.nil? || request.to_s.strip.empty?

    segments = request.to_s.split(/\n\n+/)
    if segments.size < 2 || !segments.all? { |seg| seg.match?(/\A\d+\.\s/) }
      return [{ type: type, text: request.to_s }]
    end

    segments.map { |seg| { type: type, text: seg.sub(/\A\d+\.\s+/, '') } }
  end

  def last_entry_matches?(prev_list, new_entries)
    return false if prev_list.empty? || new_entries.size != 1

    entry_equal(prev_list.last, new_entries.first)
  end

  def entry_equal(a, b)
    a[:type].to_s == b[:type].to_s && a[:text].to_s.strip == b[:text].to_s.strip
  end

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
    Oj.load(content, symbol_keys: true)
  rescue Oj::ParseError
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
    env = ENV.to_h.merge(Utility.load_env_vars)
    model = LlmRouter.default_model(env)
    config = LlmRouter.config_for_model(model, env)
    return nil if config.nil?

    common = {
      model: config[:model],
      api_base_url: config[:base_url],
      api_key: config[:access_token],
      debug: false,
      progress: true
    }
    if config[:backend] == :gemini
      AskGeminiClient.new(**common)
    else
      AskGptClient.new(**common, backend: config[:backend])
    end
  end

  def build_classification_prompt(request)
    <<~HEREDOC
      Classify the following request by identifying applicable tags.

      Request:
      #{request}

      Identify applicable tags from the following list:
      #{TAGS_LIST}

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

      Last request:
      #{previous_req}

      New request:
      #{new_req}

      Tasks:
      1. Determine if the new request continues the previous work (YES) or starts a new session (NO)
      2. Identify applicable tags from the following list:
         #{TAGS_LIST.gsub("\n", "\n         ")}

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

  def append_description_task(base_prompt, step_number, format_lines)
    <<~HEREDOC
      #{base_prompt}

      #{step_number}. Generate a concise one-sentence description of this session request (under 100 characters).

      Response format (required):
      #{format_lines}
    HEREDOC
  end

  def build_analysis_and_description_prompt(new_request, previous_session)
    if previous_session
      append_description_task(
        build_continuation_analysis_prompt(new_request, previous_session[:request]).strip,
        3,
        "CONTINUATION: YES or NO\nTAGS: comma-separated tags or NONE\nDESCRIPTION: one sentence summary"
      )
    else
      append_description_task(
        build_classification_prompt(new_request).strip,
        2,
        "TAGS: comma-separated tags or NONE\nDESCRIPTION: one sentence summary"
      )
    end
  end

  def query_ask_client(client, prompt, title: nil)
    if client.is_a?(AskGeminiClient)
      client.ask([{role: "user", content: prompt}], title: title)
    else
      system_msg = "You are a request analyzer. Provide concise, structured responses."
      messages = [
        {role: "system", content: system_msg},
        {role: "user", content: prompt}
      ]
      client.ask(messages, title: title)
    end
  end

  def parse_continuation_and_description_response(response, previous_session)
    default = {continuation: false, tags: [], description: nil}
    return default unless response

    continuation = false
    if previous_session
      continuation_match = response.match(/CONTINUATION:\s*(YES|NO)/i)
      continuation = continuation_match && continuation_match[1].upcase == "YES"
    end
    tags_match = response.match(/TAGS:\s*(.+?)(?:\n|$)/i)
    tags_text = tags_match ? tags_match[1].to_s.strip : ""
    tags = extract_tags(tags_text)
    description = extract_description_from_response(response)

    {continuation: continuation, tags: tags, description: description}
  end

  def extract_description_from_response(response)
    desc_match = response.match(/DESCRIPTION:\s*(.+?)(?:\n\s*\n|\z)/im)
    return nil unless desc_match

    extract_description("Description: #{desc_match[1].to_s.strip}")
  end

  def extract_tags(tags_text)
    return [] if tags_text.empty? || tags_text.upcase == "NONE"

    tags_text.split(",").map(&:strip).select { |tag| tag.start_with?("#") }
  end

  def extract_description(response)
    return nil unless response

    description = response.to_s.strip
    description = description.gsub(/^(Description:|Session:)\s*/i, '')
    description = description.split("\n").first
    description = description[0..99] if description && description.length > 100
    description&.to_s&.strip
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
