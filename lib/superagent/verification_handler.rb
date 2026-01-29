# frozen_string_literal: true

require_relative "../agents_file_handler"

# Handles verification prompts and response parsing
class VerificationHandler
  include AgentsFileHandler

  def initialize(display, agent_executor, session_tracker: nil)
    @display = display
    @agent_executor = agent_executor
    @session_tracker = session_tracker
  end

  def build_fix_prompt(req)
    <<~HEREDOC
      Original request: #{to_utf8(req)}#{to_utf8(format_previous_requests)}

      The previous attempt failed. Please fix the implementation.

      Review the codebase and make the necessary corrections.
    HEREDOC
  end

  def format_previous_requests
    previous_requests = @session_tracker&.get_session_request_history || []
    return '' unless previous_requests.any?

    "\n\nPrevious requests in this session:\n" +
      previous_requests.map.with_index(1) { |prev_req, idx| "#{idx}. #{to_utf8(prev_req)}" }.join("\n")
  end

  def parse_res(res)
    return [false, res] if res.nil? || res.to_s.strip.empty?

    line = extract_final_verdict_line(res)
    return [false, res] unless line

    if line[:verdict] == :no
      parse_no_res(line[:text])
    else
      parse_yes_res(line[:text])
    end
  end

  def extract_final_verdict_line(text)
    last_match = nil
    text.to_s.each_line do |line|
      match = line.match(/^\s*(YES|NO)\b\s*:?\s*(.*)$/i)
      next unless match

      last_match = { verdict: match[1].casecmp('no').zero? ? :no : :yes, text: line.to_s.strip }
    end
    last_match
  end

  def parse_no_res(n)
    m = n.match(/^\s*NO\b\s*:?\s*(.*)$/i)
    return [false, 'Failed'] unless m && !m[1].to_s.strip.empty?

    [false, remove_duplicates(m[1].to_s.strip)]
  end

  def parse_yes_res(n)
    m = n.match(/^\s*YES\b\s*:?\s*(.*)$/i)
    return [true, 'Passed'] unless m && !m[1].to_s.strip.empty?

    [true, m[1].to_s.strip]
  end

  def remove_duplicates(text)
    return text if text.length < 20

    norm = text.split.join(' ')
    half = norm.length / 2
    return text if half < 10

    first = norm[0, half]
    second = (norm[half..] || '').split.join(' ')
    check_and_strip(text, first, second)
  end

  def check_and_strip(text, first, second)
    return text if second.length < 10

    duplicate_detected?(first, second) ? text.to_s[0, text.length / 2].strip : text
  end

  def duplicate_detected?(first, second)
    second.start_with?(first[0, (first.length * 0.8).to_i])
  end

  def build_verification_system_instruction
    <<~HEREDOC
      You are a tool that verifies whether code changes fully implement a requested feature.

      Task:
      Verify that the code changes fully implement the user's request without introducing bugs or regressions.

      Available information:
      - Current user request
      - Previous user requests in this session
      - Final response from the previous agent run that attempted to implement the feature

      Verification approach:
      - Review the previous agent's response to understand what was implemented
      - You may check git diff (using 'git diff') or read relevant files to verify the changes
      - Check if the changes address the user's request
      - Look for potential bugs, regressions, or missing functionality
      - Verify code quality and adherence to project guidelines

      Response format:
      - Start your response with "YES: " followed by a brief description if verification passes
      - Start your response with "NO: " followed by a brief description if verification fails

      CRITICAL requirements:
      - Your response MUST start with either "YES" or "NO" as the first word
      - Use minimal formatting only - avoid excessive markdown or formatting
      - Keep your response short and concise - one sentence is sufficient
      - The description after YES/NO should be brief and specific
      - DO NOT use thinking blocks or any other output format. Just the YES/NO response.
    HEREDOC
  end

  def build_verification_user_content(user_request, previous_agent_response)
    req_utf8 = to_utf8(user_request)
    prev_utf8 = to_utf8(previous_agent_response)
    content_parts = []
    content_parts << "Current user request: #{req_utf8}#{to_utf8(format_previous_requests)}\n\n"
    if prev_utf8 && !prev_utf8.to_s.strip.empty?
      content_parts << "Final response from previous agent run:\n#{prev_utf8.to_s.strip}\n"
    end
    content_parts.map { |p| to_utf8(p) }.join("\n")
  end

  def build_verification_prompt(req, previous_agent_response = nil)
    user_content = build_verification_user_content(req, previous_agent_response)
    guidelines = @agent_executor.guidelines_section(always_include: true)
    "#{build_verification_system_instruction}\n\n---\n\n#{guidelines}\n\n---\n\n#{user_content}"
  end

  def run_verification(model, req, previous_agent_response = nil)
    verification_prompt = build_verification_prompt(req, previous_agent_response)
    start_time = Time.now
    success, output, reason = @agent_executor.run(model, verification_prompt, verification_mode: true)
    duration = Time.now - start_time
    unless success
      desc = output.to_s.strip.empty? ? 'Verification call failed (no response)' : output.lines.first.to_s.strip
      return [false, desc, duration, true, reason == :recoverable]
    end

    verified, desc = parse_res(output.to_s.strip)
    [verified, desc || 'Failed', duration, false, false]
  end

  def retry_with_fix(model, req)
    fix_prompt = build_fix_prompt(req)
    @display.puts "Retrying #{model} with fix...".blue
    $stdout.puts ''

    success, fix_output = @agent_executor.run(model, fix_prompt)
    return [false, nil, 0, nil] unless success

    verified, desc, review_time, _call_failed, _retryable = run_verification(model, req, fix_output)
    [verified, desc, review_time, fix_output]
  end

  def to_utf8(str)
    return '' if str.nil?
    s = str.to_s.dup
    s.force_encoding(Encoding::UTF_8)
    s.valid_encoding? ? s : s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
  end
  private :to_utf8

end
