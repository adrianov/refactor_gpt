# frozen_string_literal: true

require "oj"
require "colorize"

# Calls the LLM to produce a commit plan (commits, warnings, quality_assessment impact summary, excluded_files).
class CommitPlanClient
  include AgentsFileHandler

  # Single ceiling for commit-plan user message (static sections + one unified diff body); MR uses numstat only.
  COMMIT_PLAN_USER_PAYLOAD_CHAR_LIMIT = 200 * 1024

  USER_CONTENT_SECTIONS = [
    {
      type: :static,
      key: :cli_hint,
      optional: true,
      template: "Here are hints or preferences from the user:\n\n%s\n"
    },
    {
      type: :static,
      key: :status_output,
      optional: false,
      template: "Here is the git status:\n\n%s\n"
    },
    {
      type: :diff,
      label: "(1) Uncommitted changes — SOURCE OF TRUTH for commit messages " \
             "(git diff HEAD, includes staged and unstaged):",
      key: :uncommitted_diff_output
    },
    {
      type: :static,
      key: :mr_numstat_output,
      optional: true,
      template: "(2) Already on branch vs origin/HEAD — context only (not for commit message wording). " \
                "Per-file insert/delete counts from `git diff --numstat -w origin/HEAD...` " \
                "(no unified patch for already-committed branch work):\n\n%s\n"
    },
    {
      type: :static,
      key: :recent_commits,
      optional: false,
      template: "Here is `git log -10 --oneline` (most recent first; style reference for new messages):\n\n%s\n"
    },
    {
      type: :static,
      key: :recent_commands,
      optional: true,
      template: "Here are the last 5 shell commands from the user's terminal history " \
        "(most recent last):\n\n%s\n"
    }
  ].freeze

  # Single payload ceiling: uncommitted diff budget is what remains after all static sections (incl. MR numstat).
  def self.diff_body_budgets_chars(cli_hint:, status_output:, recent_commits:, recent_commands:, mr_numstat: "")
    data = {
      cli_hint: cli_hint.to_s,
      status_output: status_output.to_s,
      recent_commits: recent_commits.to_s,
      recent_commands: recent_commands.to_s,
      mr_numstat_output: mr_numstat.to_s
    }
    static_chars = sum_static_section_lengths(data)
    header_chars = sum_diff_header_lengths
    join_slack = [USER_CONTENT_SECTIONS.size - 1, 0].max
    remaining = COMMIT_PLAN_USER_PAYLOAD_CHAR_LIMIT - static_chars - header_chars - join_slack
    remaining = remaining.positive? ? remaining : 0
    {uncommitted: remaining}
  end

  def self.sum_static_section_lengths(data)
    USER_CONTENT_SECTIONS.sum do |sec|
      next 0 unless sec[:type] == :static
      next 0 if sec[:optional] && data.fetch(sec[:key]).strip.empty?

      format(sec[:template], data.fetch(sec[:key])).length
    end
  end

  def self.sum_diff_header_lengths
    USER_CONTENT_SECTIONS.sum do |sec|
      sec[:type] == :diff ? "#{sec[:label]}\n\n".length : 0
    end
  end

  private_class_method :sum_static_section_lengths, :sum_diff_header_lengths

  def initialize(model: nil, debug: false)
    @client = OpenAiClient.new(model: model, debug: debug,
      progress_title: "Planning commits".cyan)
  end

  def ask(prompts, json: false)
    @client.ask(prompts, json: json)
  end

  def commit_plan(status_output, mr_numstat_output, uncommitted_diff_output, cli_hint, recent_commits,
    recent_commands)
    messages = [
      {role: "system", content: system_instruction},
      {role: "user",
       content: build_user_content(status_output, mr_numstat_output, uncommitted_diff_output, cli_hint,
         recent_commits, recent_commands)}
    ]
    payload_size_kb = calculate_payload_size(messages)
    raw_response = ask(messages, json: true)
    parse_commit_plan_response(raw_response, payload_size_kb)
  end

  private

  def append_section(parts, current_size_chars, max_size_chars, text)
    return current_size_chars if text.empty? || current_size_chars + text.length > max_size_chars

    parts << text
    current_size_chars + text.length
  end

  def append_static_section(parts, current_size_chars, max_size_chars, value, config)
    return current_size_chars if config[:optional] && value.empty?

    append_section(parts, current_size_chars, max_size_chars, format(config[:template], value))
  end

  def append_labeled_diff_section(parts, current_size_chars, max_size_chars, section, data)
    diff_output = data.fetch(section[:key], "").to_s
    return current_size_chars if diff_output.strip.empty?

    combined = "#{section[:label]}\n\n#{diff_output}"
    append_section(parts, current_size_chars, max_size_chars, combined)
  end

  def append_configured_section(parts, current_size_chars, max_size_chars, section, data)
    if section[:type] == :diff
      return append_labeled_diff_section(parts, current_size_chars, max_size_chars, section, data)
    end

    append_static_section(
      parts,
      current_size_chars,
      max_size_chars,
      data.fetch(section[:key], "").to_s,
      section
    )
  end

  def append_user_content_sections(parts, max_size_chars, data)
    current_size_chars = 0
    USER_CONTENT_SECTIONS.each do |section|
      current_size_chars = append_configured_section(parts, current_size_chars, max_size_chars, section, data)
    end
    current_size_chars
  end

  def build_user_content(status_output, mr_numstat_output, uncommitted_diff_output, cli_hint, recent_commits,
    recent_commands)
    data = {
      status_output: status_output,
      mr_numstat_output: mr_numstat_output,
      uncommitted_diff_output: uncommitted_diff_output,
      cli_hint: cli_hint,
      recent_commits: recent_commits,
      recent_commands: recent_commands
    }
    parts = []
    append_user_content_sections(parts, COMMIT_PLAN_USER_PAYLOAD_CHAR_LIMIT, data)
    parts.join("\n")
  end

  def parse_commit_plan_response(raw_response, payload_size_kb)
    [raw_response.strip, extract_json_object(raw_response)].each do |candidate|
      next unless candidate

      begin
        return Oj.load(candidate)
      rescue Oj::ParseError
        next
      end
    end

    puts "Failed to parse model response as JSON.".red
    puts "Payload size: #{payload_size_kb} KB".yellow
    puts "Raw response:\n#{raw_response}".red
    exit 1
  end

  def extract_json_object(text)
    start = text.index("{")
    finish = text.rindex("}")
    text[start..finish] if start && finish && finish > start
  end

  def calculate_payload_size(messages)
    body = {model: @client.model, messages: messages, response_format: {type: "json_object"}}
    json_payload = Oj.dump(body, mode: :compat)
    (json_payload.bytesize / 1024.0).round(2)
  end

  def system_instruction
    agents = load_project_rules(Dir.pwd)
    project_context = agents.empty? ? '' : "Project guidelines:\n#{agents}\n\n"
    "#{project_context}#{CommitPlanInstructions.system_instruction}"
  end
end
