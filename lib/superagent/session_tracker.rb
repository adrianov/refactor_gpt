# frozen_string_literal: true

require 'digest'
require 'oj'
require 'fileutils'
require 'open3'

# Tracks session state per project (directory). Many sessions; continuation uses latest.
# Session: request, history, failed_sessions_count, applied_fixes_count, highest_model_index.
# Model selection: applied_fixes_count (verification + bug/regression/hotfix), highest_model_index (continuation floor).
# failed_sessions_count only when tags are #bug/#regression/#hotfix.
# Classification: Before running a request, the LLM is asked whether it continues an existing session
# or starts a new one. The UI title for this step is "Classifying to a session" when there are
# existing sessions, or "Classifying request" when there are none. Same-session requests are grouped
# by permanent session_id (Excel-style A1, B1: letter = order of addition, digit = 1).
# rubocop:disable Metrics/ClassLength -- session + continuation + prompts; SessionIdRegistry already extracted
class SessionTracker
  SESSION_DIR = ConfigPath::CONFIG_DIR
  MAX_SESSION_AGE = 86400 # 24 hours
  MAX_SESSIONS = 50

  # Tags that count toward failed_sessions_count and applied_fixes_count when all attempts fail.
  FAILURE_COUNT_TAGS = %w[#bug #regression #hotfix].freeze

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
    @modified_files = []
    ensure_session_dir
  end

  # In-memory list of modified code files this run (not persisted). Max ModifiedFilesTracker::MAX_ENTRIES.
  def add_modified_files(paths)
    return if paths.nil? || paths.empty?

    @modified_files = (@modified_files + paths).uniq.last(ModifiedFilesTracker::MAX_ENTRIES)
  end

  def get_modified_files
    @modified_files || []
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

  # Returns sessions ordered by applied fixes count (lowest first), used for model selection.
  def sessions_by_failure_count
    active_sessions.sort_by { |session| applied_fixes_for_session(session) }
  end

  def applied_fixes_for_session(session)
    return 0 unless session
    session[:applied_fixes_count] || 0
  end

  def highest_model_index_for_session(session)
    return 0 unless session
    session[:highest_model_index] || 0
  end

  def load_sessions
    file = sessions_file_path
    return [] unless File.exist?(file)

    data = read_sessions_file(file)
    return [] unless data

    @session_id_registry.load_index(data.is_a?(Hash) ? data[:description_letter_index] : nil)
    normalize_sessions_list(data)
  end

  def reset_failure_count(description: nil)
    target = description.to_s.strip.empty? ? nil : find_session_by_description(description)
    if target
      modify_session_by_id(session_id_for(target)) { |s| s[:applied_fixes_count] = 0 }
    else
      modify_last_session { |s| s[:applied_fixes_count] = 0 }
    end
  end

  # Classifies the new request as continuing an existing session or new; returns continuation, tags, description.
  def analyze_continuation_and_description(new_request, _previous_session = nil)
    default = {continuation: false, tags: [], description: default_description(new_request), continuation_id: nil}
    sessions_newest_first = active_sessions_newest_first
    return default if sessions_newest_first.empty?

    prompt, title = continuation_prompt_and_title(new_request, sessions_newest_first)
    run_continuation_query(prompt, title, new_request, sessions_newest_first)
  rescue StandardError => e
    @display.puts "Warning: Failed to analyze: #{e.message}".yellow
    default
  end

  def run_continuation_query(prompt, title, new_request, sessions_newest_first)
    @display.set_output_paused(false)
    @display.flush_paused_output
    @display.reset_after_pause
    @display.puts continuation_running_message(title).green
    response = run_superagent_ask(prompt, title: title)
    return default_continuation_result(new_request) unless response

    to_show = strip_classification_title_from_response(response)
    @display.puts to_show.light_black if to_show.to_s.strip != ''
    apply_continuation_response(response, sessions_newest_first, new_request)
  end

  def continuation_running_message(title)
    suffix = title.to_s.strip.empty? ? '' : " (#{title})"
    "Running: agent ask#{suffix}"
  end

  def apply_continuation_response(response, sessions_newest_first, new_request)
    result = parse_continuation_and_description_response(response, sessions_newest_first, new_request)
    result[:description] = description_or_default(result[:description], new_request)
    result
  end

  def default_continuation_result(new_request)
    {continuation: false, tags: [], description: default_description(new_request), continuation_id: nil}
  end

  def run_superagent_ask(prompt, title: nil)
    script = File.join(Utility::PROJECT_ROOT, 'superagent.rb')
    return nil unless File.file?(script)

    stdin_data = classification_title?(title) || title.to_s.strip.empty? ? prompt : "TITLE: #{title}\n\n#{prompt}"
    out, _, status = Open3.capture3(
      { 'RUBYOPT' => nil },
      RbConfig.ruby, script, 'ask',
      stdin_data: stdin_data,
      chdir: Utility::PROJECT_ROOT
    )
    return nil unless status.success?

    out.to_s.strip
  end

  def classification_title?(title)
    ['Classifying to a session', 'Classifying request'].include?(title.to_s.strip)
  end

  # True when text is a classification title (with or without "TITLE:" prefix), or when the first line is.
  def classification_title_as_request?(text)
    return false if text.to_s.strip.empty?
    first_line = text.to_s.strip.lines.first.to_s.strip
    stripped = first_line.sub(/\ATITLE:\s*/i, '').strip
    classification_title?(stripped)
  end

  # So the continuation output never shows "TITLE: Classifying to a session" as the request line.
  def strip_classification_title_from_response(response)
    return response if response.to_s.strip.empty?
    header = "Request to classify (not yet addressed):"
    placeholder = "\n(current request; see context)"
    response.to_s
      .gsub(/#{Regexp.escape(header)}\nTITLE: Classifying to a session/i, "#{header}#{placeholder}")
      .gsub(/#{Regexp.escape(header)}\nTITLE: Classifying request/i, "#{header}#{placeholder}")
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

  # Derives request type for changelog from tags (e.g. #bug/#regression/#hotfix → "fix").
  def request_type_from_tags(tags)
    counts_as_failure?(tags) ? 'fix' : DEFAULT_REQUEST_TYPE
  end

  def save_session(request, description, tags, continuation, last_agent_summary = :not_provided,
                   request_type: DEFAULT_REQUEST_TYPE, update_in_place: false, all_attempts_failed: false,
                   applied_fix_this_run: false, highest_model_index_this_run: nil)
    previous_session = session_for_continuation_analysis(description)
    ctx = session_save_context(previous_session, request, continuation, last_agent_summary, request_type,
                              tags: tags, all_attempts_failed: all_attempts_failed,
                              applied_fix_this_run: applied_fix_this_run,
                              highest_model_index_this_run: highest_model_index_this_run)
    session_data = build_session_data(
      request: request, description: description, tags: tags, continuation: continuation,
      request_history: ctx[:request_history], last_agent_summary: ctx[:agent_summary],
      failed_sessions_count: ctx[:failed_sessions_count], applied_fixes_count: ctx[:applied_fixes_count],
      highest_model_index: ctx[:highest_model_index]
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
                         failed_sessions_count: 0, applied_fixes_count: 0, highest_model_index: 0)
    session_data = {
      request: request,
      description: description,
      tags: tags,
      continuation: continuation,
      request_history: request_history,
      last_agent_summary: last_agent_summary,
      failed_sessions_count: failed_sessions_count,
      applied_fixes_count: applied_fixes_count,
      highest_model_index: highest_model_index,
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
    defaults[:failed_sessions_count] = 0 unless session.key?(:failed_sessions_count)
    defaults[:applied_fixes_count] = applied_fixes_for_session(session) unless session.key?(:applied_fixes_count)
    defaults[:highest_model_index] = highest_model_index_for_session(session) unless session.key?(:highest_model_index)
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
    set_session_count_defaults(session)
    session[:request_history] ||= []
    session[:tags] ||= []
    session[:continuation] ||= false
    session[:session_id] ||= description_to_session_id(session[:description]) if session[:description]
  end

  def set_session_count_defaults(session)
    session[:failed_sessions_count] ||= 0
    session[:applied_fixes_count] = applied_fixes_for_session(session)
    session[:highest_model_index] = highest_model_index_for_session(session) if session[:highest_model_index].nil?
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

  def counts_as_failure?(tags)
    return false if tags.nil? || !tags.is_a?(Array)

    normalized = tags.map { |t| t.to_s.strip.downcase }
    FAILURE_COUNT_TAGS.any? { |tag| normalized.include?(tag.downcase) }
  end

  def calculate_failed_sessions_count_context(previous_session, all_attempts_failed)
    base = previous_session ? (previous_session[:failed_sessions_count] || 0) : 0
    all_attempts_failed ? base + 1 : base
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
      failed_sessions_count: base_session[:failed_sessions_count] || 0,
      applied_fixes_count: applied_fixes_for_session(base_session),
      highest_model_index: highest_model_index_for_session(base_session)
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

  def session_save_context(previous_session, request, continuation, last_agent_summary, request_type,
                           tags: [], all_attempts_failed: false, applied_fix_this_run: false,
                           highest_model_index_this_run: nil)
    count_as_failure = all_attempts_failed && counts_as_failure?(tags)
    failed_sessions_count = calculate_failed_sessions_count_context(previous_session, count_as_failure)
    prev_applied = applied_fixes_for_session(previous_session)
    applied_fixes_count = prev_applied + (count_as_failure || applied_fix_this_run ? 1 : 0)
    prev_highest = highest_model_index_for_session(previous_session)
    highest_model_index = if highest_model_index_this_run.nil?
                            prev_highest
                          else
                            [prev_highest, highest_model_index_this_run].max
                          end
    {
      request_history: build_request_history_context(previous_session, request, request_type),
      agent_summary: determine_agent_summary_context(continuation, previous_session, last_agent_summary),
      failed_sessions_count: failed_sessions_count,
      applied_fixes_count: applied_fixes_count,
      highest_model_index: highest_model_index
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

  # Builds continuation-analysis prompt. Request to classify on top; then sessions as table (title left, content right).
  # When the newest session has last_agent_summary, it is included so continuation and tag decisions build on it.
  # If new_req is a classification title (e.g. "TITLE: Classifying to a session"), use a placeholder so the prompt
  # never shows the title as the request.
  def build_continuation_analysis_prompt(new_req, sessions_newest_first)
    session_lines = continuation_session_lines(sessions_newest_first)
    last_run_block = last_run_result_block(sessions_newest_first.first)
    display_req = new_req.to_s.strip
    display_req = '(current request; see context)' if classification_title_as_request?(display_req)
    <<~HEREDOC
      Request to classify (not yet addressed):
      #{display_req}

      Existing sessions (newest first, by numerical ID). Each row: session number on the left, content on the right:
      #{session_lines}
      #{last_run_block}

      Tasks:
      1. CONTINUATION: Answer CONTINUATION: <number> only when the request clearly concerns the same feature or task
         as that session (e.g. extending it or fixing a defect in that feature). Answer CONTINUATION: NEW if the
         request is about a different topic, another feature, or unrelated behavior (e.g. UI messages, config, logs).
      2. TAGS: From the list below, pick tags that apply. Use #bug, #regression, or #hotfix only when it fixes a defect.
         Use other tags for extending the same feature or when starting something new.
         #{TAGS_LIST.gsub("\n", "\n         ")}

      When recap, summary, or result from the last run is shown above, use it so continuation and tag decisions build on that outcome.
      For external products or APIs, use web fetch to consult official docs to classify accurately.

      Response format (required). Request to classify on top; then one row per field with title on the left, content on the right:
      CONTINUATION: <number> or NEW
      TAGS: comma-separated tags (e.g., #bug, #feature) or NONE

      Examples (session 1 = "add login with email and password"):
      - "fix the bug where login fails when email has spaces" → CONTINUATION: 1, TAGS: #bug
      - "also add 'forgot password'" → CONTINUATION: 1, TAGS: #feature
      - "add a user dashboard" → CONTINUATION: NEW, TAGS: #feature
      - "the validation we added is wrong, fix it" → CONTINUATION: 1, TAGS: #bug
      - "when usage limit reached always show the message" (different topic) → CONTINUATION: NEW, TAGS: #improvement
    HEREDOC
  end

  def continuation_session_lines(sessions_newest_first)
    sessions_newest_first.each_with_index.map { |s, i| continuation_session_row(s, i) }.join("\n")
  end

  def continuation_session_row(session, index)
    desc = (session[:description] || session[:request].to_s[0..80]).to_s.strip
    addressed = already_addressed_preview(session, max_entries: 5, max_len: 80)
    row_content = desc.dup
    row_content += "\n   Already addressed in this session: #{addressed}" if addressed && !addressed.empty?
    "#{index + 1}.\t#{row_content.gsub("\n", "\n\t")}"
  end

  def already_addressed_preview(session, max_entries: 5, max_len: 80)
    list = previous_request_history_list(session)
    return nil if list.nil? || list.empty?

    parts = list.last(max_entries).map do |req|
      text = (req[:text] || '').to_s.strip
      short = text.length > max_len ? "#{text[0...(max_len - 3)]}..." : text
      "(#{req[:type]}) #{short}"
    end
    parts.join('; ')
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
