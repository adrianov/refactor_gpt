# frozen_string_literal: true

require 'rbconfig'

# Session-aware blocks on an agent prompt: Cursor rules, git state, history, and host facts.
class AgentPromptContext
  include AgentsFileHandler

  CONTEXT_MAX_LINES = 500
  MAX_PREVIOUS_REQUESTS = 5

  def initialize(session_tracker)
    @session_tracker = session_tracker
  end

  def context_parts(new_session, fix_stage: false)
    parts = []
    if new_session
      parts << non_interactive_notice
      parts << guidelines_section(always_include: true, fix_stage: false)
    end
    parts << guidelines_section(always_include: true, fix_stage: true) if fix_stage
    parts << user_context_section
    parts.concat(optional_context_sections(new_session))
  end

  def guidelines_section(always_include: false, fix_stage: false)
    raw = fix_stage ? read_agents_files_with_dev.to_s.strip : read_agents_files.to_s.strip
    default = load_refactor_md.to_s.strip
    content = guidelines_body(raw, default, always_include)
    content.empty? ? '' : "\n\n#{AgentsFileHandler::RULES_LABEL}:\n#{content}"
  end

  def summary_section(session_description: nil)
    summary = @session_tracker&.get_last_agent_summary(description: session_description)
    return nil if summary.nil? || summary.to_s.strip.empty?

    "\n\nFinal summary from previous agent run:\n#{summary}"
  end

  def history_section(current_request: nil, session_description: nil)
    recent, start_num, width = recent_request_history_slice(current_request, session_description)
    return nil if recent.nil? || recent.empty?

    history_header(recent.size, session_description) + format_previous_requests_body(recent, start_num, width)
  end

  def modified_files_section
    list = @session_tracker&.get_modified_files || []
    return nil if list.empty?

    "\n\nModified code files in this session (max #{ModifiedFilesTracker::MAX_ENTRIES}):\n#{list.join("\n")}"
  end

  def non_interactive_notice
    "\n\nIMPORTANT: This agent runs in non-interactive mode. " \
    "You must make all decisions autonomously and execute tasks directly " \
    "without requesting user input, clarification, or confirmation. " \
    "Proceed with implementation based on the available context and your best judgment."
  end

  private

  def guidelines_body(raw, default, always_include)
    return default if raw.empty?
    return raw unless always_include && !default.empty?

    "#{raw}\n\n#{default}"
  end

  def user_context_section
    parts = [
      "Current time: #{Time.now.strftime("%A, %B %d, %Y at %I:%M %p %Z")}",
      "OS: #{RbConfig::CONFIG['host_os']}",
      "Shell: #{ENV['SHELL']}",
      "User: #{ENV['USER'] || ENV['USERNAME']}",
      "Project root: #{Dir.pwd}"
    ]
    "\n\n" + parts.join("\n")
  end

  def optional_context_sections(new_session)
    [
      command_section(new_session, 'Git status', "git status 2>#{File::NULL}"),
      command_section(new_session, 'Last 10 git log entries (newest first)',
        "git log -10 --pretty=format:'%h %s' 2>#{File::NULL}"),
      truncated_command_section(new_session, 'Git diff', "git diff 2>#{File::NULL}"),
      truncated_command_section(new_session, 'Working tree (bfs --nohidden)', "bfs --nohidden 2>#{File::NULL}"),
      modified_files_section
    ].compact
  end

  def command_section(new_session, heading, command)
    return nil unless new_session

    out = `#{command}`.strip
    return nil if out.empty?

    "\n\n#{heading}:\n#{out}"
  end

  def truncated_command_section(new_session, label, command)
    return nil unless new_session

    format_truncated_section(label, `#{command}`.strip)
  end

  def format_truncated_section(label, content, max_lines: CONTEXT_MAX_LINES)
    return nil if content.nil? || content.to_s.strip.empty?

    lines = content.split("\n", -1)
    truncated = lines.size > max_lines
    text = lines.first(max_lines).join("\n")
    text += "\n\n(truncated to #{max_lines} lines)" if truncated
    "\n\n#{label} (max #{max_lines} lines):\n#{text}"
  end

  def read_dev_md
    path = File.join(Dir.pwd, 'DEV.md')
    File.exist?(path) ? read_utf8_file(path).strip : ''
  end

  def read_agents_files
    load_project_rules(Dir.pwd)
  end

  def read_agents_files_with_dev
    [read_dev_md, read_agents_files].reject(&:empty?).join("\n\n")
  end

  def history_header(count, session_description)
    if session_description && !session_description.to_s.strip.empty?
      "\n\nAlready addressed in this session (oldest to newest, last #{count}):\n"
    else
      "\n\nPrevious requests in this project (oldest to newest, last #{count}):\n"
    end
  end

  def format_previous_requests_body(recent, start_num, width)
    lines = recent.each_with_index.map { |req, i| format_previous_request_line(start_num + i, width, req) }
    compact_to_two_lines(lines.map { |s| s.length > 38 ? "#{s[0...35]}..." : s })
  end

  def compact_to_two_lines(parts)
    mid = (parts.size + 1) / 2
    line1 = parts.first(mid).join(' | ')
    line2 = parts.drop(mid).join(' | ')
    [line1, line2].reject(&:empty?).join("\n")
  end

  def recent_request_history_slice(current_request, session_description = nil)
    full = @session_tracker&.get_session_request_history(
      exclude_equal: current_request, description: session_description
    ) || []
    return [nil, 0, 0] if full.empty?

    recent = full.last(MAX_PREVIOUS_REQUESTS)
    start_num = full.size - recent.size + 1
    last_num = start_num + recent.size - 1
    width = [2, last_num.to_s.length].max
    [recent, start_num, width]
  end

  def format_previous_request_line(num, width, req)
    "#{num.to_s.rjust(width)}. (#{req[:type]}) #{req[:text]}"
  end
end
