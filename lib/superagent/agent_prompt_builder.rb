# frozen_string_literal: true

require 'rbconfig'

# Builds the context and guidelines blocks appended to agent prompts.
# Used by AgentExecutor so prompt logic stays under length/ABC limits.
class AgentPromptBuilder
  CONTEXT_MAX_LINES = 500
  MAX_PREVIOUS_REQUESTS = 5

  # Phrase used when instructing the model to follow project rules (e.g. in refactor/verification prompts).
  # Files are attached; do not tell the model to read specific filenames.
  GUIDELINE_REFERENCE_PHRASE = 'Follow the project rules already provided in context.'

  # Phrase used in verification system instruction for how to verify changes.
  # Context is attached; do not instruct the model to read files again.
  VERIFICATION_FILES_PHRASE = "You may run 'git diff' or use the attached context to verify the changes."

  def initialize(session_tracker)
    @session_tracker = session_tracker
  end

  def wrap_prompt(p, new_session: false, current_request: nil, verification_mode: false, continuation_analysis: nil)
    user_content = format_user_request_content(p, continuation_analysis)
    rest = context_parts(new_session).compact.join
    history = verification_mode ? nil : history_section(current_request: current_request)
    summary = summary_section
    user_content + (history.to_s + summary.to_s + rest)
  end

  # Single place to build the user request block sent to the agent. Prepends CONTINUATION/TAGS/DESCRIPTION when present.
  def format_user_request_content(request_text, continuation_analysis)
    return request_text.to_s if continuation_analysis.nil? || continuation_analysis.empty?

    continuation_request_header(continuation_analysis) + request_text.to_s
  end

  def user_context_section
    parts = []
    parts << "Current time: #{Time.now.strftime("%A, %B %d, %Y at %I:%M %p %Z")}"
    parts << "OS: #{RbConfig::CONFIG['host_os']}"
    parts << "Shell: #{ENV['SHELL']}"
    parts << "User: #{ENV['USER'] || ENV['USERNAME']}"
    parts << "Project root: #{Dir.pwd}"
    "\n\n" + parts.join("\n")
  end

  def git_status_section(new_session)
    return nil unless new_session
    out = `git status 2>#{File::NULL}`.strip
    return nil if out.empty?
    "\n\nGit status:\n#{out}"
  end

  def git_log_section(new_session)
    return nil unless new_session
    out = `git log -10 --pretty=format:'%h %s' 2>#{File::NULL}`.strip
    return nil if out.empty?
    "\n\nLast 10 git log entries (newest first):\n#{out}"
  end

  def git_diff_section(new_session)
    return nil unless new_session
    format_truncated_section('Git diff', `git diff 2>#{File::NULL}`.strip)
  end

  def working_tree_section(new_session)
    return nil unless new_session
    format_truncated_section('Working tree (bfs --nohidden)', `bfs --nohidden 2>#{File::NULL}`.strip)
  end

  def guidelines_section(always_include: false)
    raw = read_agents_files.to_s.strip
    default = default_refactor_instructions.to_s.strip
    content = if raw.empty?
                default.empty? ? '' : "Project guidelines:\n#{default}"
              else
                suffix = always_include && !default.empty? ? "\n\n#{default}" : ''
                "Project guidelines:\n#{raw}#{suffix}"
              end
    content.empty? ? '' : "\n\n#{content}"
  end

  def summary_section
    summary = @session_tracker&.get_last_agent_summary
    return nil if summary.nil? || summary.to_s.strip.empty?

    "\n\nFinal summary from previous agent run:\n#{summary}"
  end

  # Builds "Previous requests" prompt block: last N entries, direct order (oldest to newest).
  # Header and body are separate so body format (e.g. one line per request vs compact 2 lines) can change in one place.
  def history_section(current_request: nil)
    recent, start_num, width = recent_request_history_slice(current_request)
    return nil if recent.nil? || recent.empty?

    previous_requests_header(recent.size) + format_previous_requests_body(recent, start_num, width)
  end

  def non_interactive_notice
    "\n\nIMPORTANT: This agent runs in non-interactive mode. " \
    "You must make all decisions autonomously and execute tasks directly " \
    "without requesting user input, clarification, or confirmation. " \
    "Proceed with implementation based on the available context and your best judgment."
  end

  def context_parts(new_session)
    parts = []
    if new_session
      parts << non_interactive_notice
      parts << guidelines_section(always_include: true)
    end
    parts << user_context_section
    parts << git_status_section(new_session)
    parts << git_log_section(new_session)
    parts << git_diff_section(new_session)
    parts << working_tree_section(new_session)
    parts
  end

  private

  def continuation_request_header(analysis)
    lines = []
    lines << "[#{Time.now.strftime('%H:%M:%S')}] CONTINUATION: #{analysis[:continuation] ? 'YES' : 'NO'}"
    tags = analysis[:tags] || []
    lines << "TAGS: #{tags.empty? ? 'NONE' : tags.join(', ')}"
    desc = analysis[:description]
    lines << "DESCRIPTION: #{desc}" if desc && !desc.to_s.strip.empty?
    lines << ''
    lines.join("\n")
  end

  def format_truncated_section(label, content, max_lines: CONTEXT_MAX_LINES)
    return nil if content.nil? || content.to_s.strip.empty?

    lines = content.split("\n", -1)
    truncated = lines.size > max_lines
    text = lines.first(max_lines).join("\n")
    text += "\n\n(truncated to #{max_lines} lines)" if truncated
    "\n\n#{label} (max #{max_lines} lines):\n#{text}"
  end

  def read_agents_files
    root = Dir.pwd
    parts = %w[AGENTS.md .cursorrules].filter_map do |name|
      path = File.join(root, name)
      next unless File.exist?(path)

      File.read(path).strip
    end
    parts.empty? ? '' : parts.join("\n\n")
  end

  def default_refactor_instructions
    path = File.expand_path('../../REFACTOR.md', __dir__)
    File.exist?(path) ? File.read(path).strip : ''
  end

  def previous_requests_header(count)
    "\n\nPrevious requests in this project (oldest to newest, last #{count}):\n"
  end

  # Renders the list of recent requests for the prompt in at most 2 lines (first half | second half).
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

  def recent_request_history_slice(current_request)
    full = @session_tracker&.get_session_request_history(exclude_equal: current_request) || []
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
