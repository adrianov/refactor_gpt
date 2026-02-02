# frozen_string_literal: true

require 'digest'
require 'oj'
require 'fileutils'

# Tracks session state per project (directory). Many sessions; continuation uses latest.
# Session: request, history, continuation, failure_count, step_count. /reset clears failure_count.
# Classification: Before running a request, the LLM is asked whether it continues an existing session
# or starts a new one. The UI title for this step is "Classifying to a session" when there are
# existing sessions, or "Classifying request" when there are none. Same-session requests are grouped
# by permanent session_id (Excel-style A1, B1: letter = order of addition, digit = 1).
# rubocop:disable Metrics/ClassLength -- session + continuation + prompts; SessionIdRegistry already extracted
class SessionTracker
  SESSION_DIR = ConfigPath::CONFIG_DIR
  MAX_SESSION_AGE = 86400 # 24 hours
  MAX_SESSIONS = 50

  TAGS_LIST = (<<~TAGS
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
  ).strip

  def initialize(display)
    @display = display
    @session_id_registry = SessionIdRegistry.new(
      read_index: -> { read_description_letter_index },
      persist_index: method(:persist_description_letter_index)
    )
    ensure_session_dir
  end

  def load_previous_session
    list = load_sessions
    return nil if list.empty?

    last = list.last
    return nil unless last && !session_expired?(last)

    last
  end

  # Session used for continuation analysis and prompt history/summary.
  # When description is given, returns the session whose description matches (same session id); else latest.
  def session_for_continuation_analysis(description = nil)
    return load_previous_session if description.nil? || description.to_s.strip.empty?

    find_session_by_description(description) || load_previous_session
  end

  # Returns the most recent session whose description matches (by session_id or description), or nil.
  def find_session_by_description(description)
    id = description_to_session_id(description)
    if id && !id.empty?
      found = active_sessions.reverse.find { |s| session_id_for(s) == id }
      return found if found
    end
    active_sessions.reverse.find { |s| @session_id_registry.descriptions_match(s[:description], description) }
  end

  # Returns all non-expired sessions for this project, ordered by most recent first.
  def active_sessions
    load_sessions.select { |session| !session_expired?(session) }
  end

  # Sessions ordered newest first, for display and continuation prompt (1-based index = id).
  def active_sessions_newest_first
    active_sessions.reverse
  end

  # Returns session at 1-based numerical id (1 = newest), or nil.
  def session_by_numerical_id(id)
    return nil unless id.is_a?(Integer) && id >= 1

    list = active_sessions_newest_first
    list[id - 1]
  end

  # Returns sessions ordered by failure count (lowest first), useful for model selection.
  def sessions_by_failure_count
    active_sessions.sort_by { |session| session[:failure_count] || 0 }
  end

  # Gets the failure count for a specific session, defaulting to 0 if not found.
  def failure_count_for_session(session)
    return 0 unless session
    session[:failure_count] || 0
  end

  def load_sessions
    file = sessions_file_path
    return [] unless File.exist?(file)

    data = read_sessions_file(file)
    return [] unless data

    @session_id_registry.load_index(data.is_a?(Hash) ? data[:description_letter_index] : nil)
    normalize_sessions_list(data)
  end

  def increment_failure_count(description: nil)
    target = description.to_s.strip.empty? ? nil : find_session_by_description(description)
    if target
      modify_session_by_id(session_id_for(target)) do |session|
        session[:failure_count] = (session[:failure_count] || 0) + 1
      end
    else
      modify_last_session { |session| session[:failure_count] = (session[:failure_count] || 0) + 1 }
    end
  end

  def reset_failure_count(description: nil)
    target = description.to_s.strip.empty? ? nil : find_session_by_description(description)
    if target
      modify_session_by_id(session_id_for(target)) { |session| session[:failure_count] = 0 }
    else
      modify_last_session { |session| session[:failure_count] = 0 }
    end
  end

  # Classifies the new request as continuing an existing session or new; returns continuation, tags, description.
  def analyze_continuation_and_description(new_request, _previous_session = nil)
    client = create_ask_client
    default = {continuation: false, tags: [], description: default_description(new_request), continuation_id: nil}
    return default unless client

    sessions_newest_first = active_sessions_newest_first
    return default if sessions_newest_first.empty?

    prompt, title = continuation_prompt_and_title(new_request, sessions_newest_first)
    run_continuation_query(client, prompt, title, new_request, sessions_newest_first)
  rescue StandardError => e
    @display.puts "Warning: Failed to analyze: #{e.message}".yellow
    default
  end

  def run_continuation_query(client, prompt, title, new_request, sessions_newest_first)
    response = query_ask_client(client, prompt, title: title)
    @display.puts response.light_black if response && !response.to_s.strip.empty?
    result = parse_continuation_and_description_response(response, sessions_newest_first, new_request)
    result[:description] = description_or_default(result[:description], new_request)
    result
  end

  # UI title for the classification LLM call: "Classifying to a session" when there are existing
  # sessions (user sees that we are matching the new request to a session), else "Classifying request".
  def continuation_prompt_and_title(new_request, sessions_newest_first)
    prompt = build_analysis_and_description_prompt(new_request, sessions_newest_first)
    title = sessions_newest_first.any? ? "Classifying to a session" : "Classifying request"
    [prompt, title]
  end

  def default_description(request)
    "Session: #{request[0..100]}..."
  end

  def description_or_default(description, request)
    (description.nil? || description.to_s.strip.empty?) ? default_description(request) : description
  end

  DEFAULT_REQUEST_TYPE = 'implementation'

  def save_session(request, description, tags, continuation, last_agent_summary = :not_provided,
                   request_type: DEFAULT_REQUEST_TYPE, update_in_place: false)
    previous_session = session_for_continuation_analysis(description)
    ctx = session_save_context(previous_session, request, continuation, last_agent_summary, request_type)
    session_data = build_session_data(
      request: request, description: description, tags: tags, continuation: continuation,
      request_history: ctx[:request_history], last_agent_summary: ctx[:agent_summary],
      failure_count: ctx[:failure_count], step_count: ctx[:step_count]
    )
    list = session_list_for_save(load_sessions, session_data, continuation, update_in_place)
    write_sessions(list.last(MAX_SESSIONS))
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
    sessions = load_sessions
    return if sessions.empty?

    updated_session = merge_request_history_into_session(
      session_with_defaults(previous || sessions[-1] || {}),
      prev_list + new_entries
    )
    sessions[-1] = updated_session
    write_sessions(sessions)
  end

  def build_session_data(request:, description:, tags:, continuation:, request_history:, last_agent_summary:,
                         failure_count: 0, step_count: 0)
    session_data = {
      request: request,
      description: description,
      tags: tags,
      continuation: continuation,
      request_history: request_history,
      last_agent_summary: last_agent_summary,
      failure_count: failure_count,
      step_count: step_count,
      timestamp: Time.now.to_i,
      cwd: Dir.pwd,
      session_id: description_to_session_id(description)
    }

    raise "Invalid session structure" unless validate_session_structure(session_data)

    session_data
  end

  def get_session_request_history(exclude_equal: nil, description: nil)
    session_data = session_for_continuation_analysis(description)
    return [] unless session_data

    list = previous_request_history_list(session_data)
    return list if exclude_equal.nil? || exclude_equal.to_s.strip.empty?

    exclude = RequestPreparer.normalized_request_text(exclude_equal)
    list.reject { |req| RequestPreparer.normalized_request_text(req[:text]) == exclude }
  end

  def get_last_agent_summary(description: nil)
    session_data = session_for_continuation_analysis(description)
    return nil unless session_data

    session_data[:last_agent_summary]
  end

  private

  def session_with_defaults(session)
    return {} unless session.is_a?(Hash)

    defaults = {}
    defaults[:failure_count] = 0 unless session.key?(:failure_count)
    defaults[:step_count] = 0 unless session.key?(:step_count)
    defaults.empty? ? session : session.merge(defaults)
  end

  def validate_session_structure(session)
    return false unless session.is_a?(Hash)
    return false unless valid_request?(session[:request])
    return false unless valid_timestamp?(session[:timestamp])

    set_session_defaults(session)
    true
  end

  def valid_request?(request)
    request.is_a?(String) && (request && !request.to_s.strip.empty?)
  end

  def valid_timestamp?(timestamp)
    timestamp.is_a?(Integer) && timestamp > 0
  end

  def set_session_defaults(session)
    session[:failure_count] ||= 0
    session[:step_count] ||= 0
    session[:request_history] ||= []
    session[:tags] ||= []
    session[:continuation] ||= false
    session[:session_id] ||= description_to_session_id(session[:description]) if session[:description]
  end

  public

  # Permanent Excel-style session ID (e.g. A1, B1): letter = order of addition, digit = 1.
  def description_to_session_id(description)
    @session_id_registry.description_to_session_id(description)
  end

  private

  def read_description_letter_index
    data = read_sessions_file(sessions_file_path)
    idx = data.is_a?(Hash) && data[:description_letter_index].is_a?(Array) ? data[:description_letter_index] : []
    idx.dup
  end

  def persist_description_letter_index(index)
    data = read_sessions_file(sessions_file_path) || {}
    data = { sessions: [] } unless data.is_a?(Hash)
    data[:sessions] ||= []
    data[:description_letter_index] = index
    ensure_session_dir
    File.write(sessions_file_path, Oj.dump(data, mode: :compat, indent: 2))
  end

  def build_request_history_context(previous_session, request, request_type)
    prev_list = previous_request_history_list(previous_session)
    new_entries = expand_combined(request, type: request_type)
    last_entry_matches?(prev_list, new_entries) ? prev_list : prev_list + new_entries
  end

  def determine_agent_summary_context(continuation, previous_session, last_agent_summary)
    determine_agent_summary(continuation, previous_session, last_agent_summary)
  end

  def calculate_failure_count_context(continuation, previous_session)
    continuation && previous_session ? (previous_session[:failure_count] || 0) : 0
  end

  def calculate_step_count_context(continuation, previous_session)
    continuation && previous_session ? (previous_session[:step_count] || 0) + 1 : 0
  end

  def determine_session_save_strategy(current_sessions, new_session_data, continuation)
    if continuation && current_sessions.any?
      sid = new_session_data[:session_id]
      idx = sid ? current_sessions.index { |s| session_id_for(s) == sid } : nil
      replace_at = idx.nil? ? current_sessions.size - 1 : idx
      current_sessions.dup.tap { |list| list[replace_at] = new_session_data }
    else
      current_sessions + [new_session_data]
    end
  end

  def session_id_for(session)
    session[:session_id] || description_to_session_id(session[:description])
  end

  def merge_request_history_into_session(base_session, new_history_entries)
    base_session.merge(
      request_history: new_history_entries,
      timestamp: Time.now.to_i,
      cwd: Dir.pwd,
      failure_count: base_session[:failure_count] || 0,
      step_count: base_session[:step_count] || 0
    )
  end

  def modify_last_session
    sessions = load_sessions
    return if sessions.empty?

    yield sessions.last
    write_sessions(sessions)
  end

  def modify_session_by_id(session_id)
    sessions = load_sessions
    idx = sessions.index { |s| session_id_for(s) == session_id }
    return if idx.nil?

    yield sessions[idx]
    write_sessions(sessions)
  end

  def session_list_for_save(sessions, session_data, continuation, update_in_place)
    if update_in_place && sessions.any?
      sid = session_data[:session_id]
      idx = sid ? sessions.index { |s| session_id_for(s) == sid } : nil
      replace_at = idx.nil? ? sessions.size - 1 : idx
      return sessions.dup.tap { |list| list[replace_at] = session_data }
    end

    determine_session_save_strategy(sessions, session_data, continuation)
  end

  def session_save_context(previous_session, request, continuation, last_agent_summary, request_type)
    {
      request_history: build_request_history_context(previous_session, request, request_type),
      agent_summary: determine_agent_summary_context(continuation, previous_session, last_agent_summary),
      failure_count: calculate_failure_count_context(continuation, previous_session),
      step_count: calculate_step_count_context(continuation, previous_session)
    }
  end

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
    return false unless a[:type].to_s == b[:type].to_s

    norm_a = RequestPreparer.normalized_request_text(a[:text])
    norm_b = RequestPreparer.normalized_request_text(b[:text])
    norm_a == norm_b
  end

  def ensure_session_dir
    FileUtils.mkdir_p(SESSION_DIR)
  end

  def sessions_file_path
    File.join(SESSION_DIR, "#{ConfigPath.project_id}.json")
  end

  def read_sessions_file(file_path)
    return nil unless File.exist?(file_path)

    content = File.read(file_path)
    Oj.load(content, symbol_keys: true)
  rescue Oj::ParseError
    nil
  rescue StandardError
    nil
  end

  def normalize_sessions_list(data)
    raw = if data.is_a?(Array)
            data
          elsif data.is_a?(Hash) && data[:sessions].is_a?(Array)
            data[:sessions]
          elsif data.is_a?(Hash) && data.key?(:request)
            [data]
          else
            []
          end
    raw.select { |s| s.is_a?(Hash) }.map do |session|
      normalized = session_with_defaults(session)
      validate_session_structure(normalized) ? normalized : nil
    end.compact
  end

  def write_sessions(list)
    ensure_session_dir
    active_sessions = list.select { |session| !session_expired?(session) }.last(MAX_SESSIONS)
    payload = { sessions: active_sessions.map { |s| s.is_a?(Hash) ? s : {} } }
    idx = @session_id_registry.description_letter_index
    payload[:description_letter_index] = idx if idx.is_a?(Array)
    File.write(sessions_file_path, Oj.dump(payload, mode: :compat, indent: 2))
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

  # Builds continuation-analysis prompt. When the newest session has last_agent_summary (recap/summary/result),
  # includes it so continuation and tag decisions build on that outcome.
  def build_continuation_analysis_prompt(new_req, sessions_newest_first)
    session_lines = sessions_newest_first.each_with_index.map do |s, i|
      desc = (s[:description] || s[:request].to_s[0..80]).to_s.strip
      "#{i + 1}. #{desc}"
    end.join("\n")
    last_run_block = last_run_result_block(sessions_newest_first.first)
    <<~HEREDOC
      Existing sessions (newest first, by numerical ID):
      #{session_lines}
      #{last_run_block}

      New request:
      #{new_req}

      Tasks:
      1. CONTINUATION: Answer CONTINUATION: <number> if the new request concerns the same feature or task
         (e.g. extending it or fixing a defect). Answer CONTINUATION: NEW if a different feature or new session.
      2. TAGS: From the list below, pick tags that apply. Use #bug, #regression, or #hotfix only when it fixes a defect.
         Use other tags for extending the same feature or when starting something new.
         #{TAGS_LIST.gsub("\n", "\n         ")}

      When recap, summary, or result from the last run is shown above, use it so continuation and tag decisions build on that outcome.
      For external products or APIs, use web fetch to consult official docs to classify accurately.

      Response format (required):
      CONTINUATION: <number> or NEW
      TAGS: comma-separated tags (e.g., #bug, #feature) or NONE

      Examples (session 1 = "add login with email and password"):
      - "fix the bug where login fails when email has spaces" → CONTINUATION: 1, TAGS: #bug
      - "also add 'forgot password'" → CONTINUATION: 1, TAGS: #feature
      - "add a user dashboard" → CONTINUATION: NEW, TAGS: #feature
      - "the validation we added is wrong, fix it" → CONTINUATION: 1, TAGS: #bug
    HEREDOC
  end

  def last_run_result_block(newest_session)
    summary = newest_session&.dig(:last_agent_summary)
    return "" if summary.nil? || summary.to_s.strip.empty?

    "\nLast run (recap / summary / result):\n#{summary.to_s.strip}\n"
  end

  def append_description_task(base_prompt, step_number, format_lines)
    <<~HEREDOC
      #{base_prompt}

      #{step_number}. Generate a concise one-sentence description of this session request (under 100 characters).

      Response format (required):
      #{format_lines}
    HEREDOC
  end

  def build_analysis_and_description_prompt(new_request, sessions_newest_first)
    if sessions_newest_first.any?
      append_description_task(
        build_continuation_analysis_prompt(new_request, sessions_newest_first).to_s.strip,
        3,
        "CONTINUATION: <number> or NEW\nTAGS: comma-separated tags or NONE\nDESCRIPTION: one sentence summary"
      )
    else
      append_description_task(
        build_classification_prompt(new_request).to_s.strip,
        2,
        "TAGS: comma-separated tags or NONE\nDESCRIPTION: one sentence summary"
      )
    end
  end

  def query_ask_client(client, prompt, title: nil)
    if client.is_a?(AskGeminiClient)
      client.ask([{role: "user", content: prompt}], title: title)
    else
      system_msg = "You are a request analyzer. Provide concise, structured responses. " \
        "For external products or APIs, use web fetch to consult official docs to classify accurately."
      messages = [
        {role: "system", content: system_msg},
        {role: "user", content: prompt}
      ]
      client.ask(messages, title: title)
    end
  end

  # Returns hash :continuation, :tags, :description, :continuation_id. continuation_id nil = new session (header NEW).
  def parse_continuation_and_description_response(response, sessions_newest_first, new_request)
    default = {continuation: false, tags: [], description: nil, continuation_id: nil}
    return default unless response

    cont, cont_id, desc = parse_continuation_and_desc(response, sessions_newest_first)
    description = (desc.nil? || desc.to_s.strip.empty?) ? default_description(new_request) : desc
    tags_match = response.match(/TAGS:\s*(.+?)(?:\n|$)/i)
    tags_text = tags_match ? tags_match[1].to_s.strip : ""
    tags = extract_tags(tags_text)
    {continuation: cont, tags: tags, description: description, continuation_id: cont_id}
  end

  def parse_continuation_and_desc(response, sessions_newest_first)
    return [false, nil, extract_description_from_response(response)] unless sessions_newest_first.any?

    num_match = response.match(/CONTINUATION:\s*(\d+)/i)
    if num_match
      id = num_match[1].to_i
      session = session_by_numerical_id(id)
      if session
        desc = session[:description] || session[:request].to_s[0..99]
        return [true, id, desc]
      end
    end
    [false, nil, extract_description_from_response(response)]
  end

  def extract_description_from_response(response)
    desc_match = response.match(/DESCRIPTION:\s*(.+?)(?:\n\s*\n|\z)/im)
    return nil unless desc_match

    extract_description("Description: #{desc_match[1].to_s.strip}")
  end

  def extract_tags(tags_text)
    return [] if tags_text.empty? || tags_text.upcase == "NONE"

    tags_text.split(",").map { |tag| tag.to_s.strip }.select { |tag| tag.start_with?("#") }
  end

  def extract_description(response)
    return nil unless response

    description = response.to_s.strip
    description = description.gsub(/^(Description:|Session:)\s*/i, '')
    description = description.split("\n").first
    description = description[0..99] if description && description.length > 100
    description.nil? ? nil : description.to_s.strip
  end
# rubocop:enable Metrics/ClassLength
end
