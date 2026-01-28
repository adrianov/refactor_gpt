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
    previous_requests_text = format_previous_requests
    <<~HEREDOC
      Original request: #{req}#{previous_requests_text}

      The previous attempt failed. Please fix the implementation.

      Review the codebase and make the necessary corrections.
    HEREDOC
  end

  def format_previous_requests
    previous_requests = @session_tracker&.get_session_request_history || []
    return '' unless previous_requests.any?

    "\n\nPrevious requests in this session:\n" +
      previous_requests.map.with_index(1) { |prev_req, idx| "#{idx}. #{prev_req}" }.join("\n")
  end

  def parse_res(res)
    return [false, res] if res.nil? || res.strip.empty?

    n = normalize_response(res)
    up = n.upcase

    # Prioritize NO if both are present and NO comes first
    yes_match = up.match(/\bYES\b/i)
    no_match = up.match(/\bNO\b/i)

    if no_match && (yes_match.nil? || no_match.begin(0) < yes_match.begin(0))
      parse_no_res(n)
    elsif yes_match
      parse_yes_res(n)
    else
      [false, res]
    end
  end

  def normalize_response(res)
    normalized = res.strip
    normalized = normalized.gsub(/\*\*(.*?)\*\*/, '\1')
    normalized = normalized.gsub(/\*(.*?)\*/, '\1')
    normalized = normalized.gsub(/__(.*?)__/, '\1')
    normalized = normalized.gsub(/_(.*?)_/, '\1')
    normalized.strip
  end

  def parse_no_res(n)
    m = n.match(/\bNO\b\s*:?\s*(.*)/i)
    return [false, 'Failed'] unless m && !m[1].strip.empty?

    [false, remove_duplicates(m[1].strip.split(/\b(?:YES|NO)\s*:?\s*/i).first.strip)]
  end

  def parse_yes_res(n)
    m = n.match(/\bYES\b\s*:?\s*(.*)/i)
    return [true, 'Passed'] unless m && !m[1].strip.empty?

    [true, remove_duplicates(m[1].strip.split(/\b(?:YES|NO)\s*:?\s*/i).first.strip)]
  end

  def remove_duplicates(text)
    return text if text.length < 20

    norm = text.gsub(/\s+/, ' ').strip
    half = norm.length / 2
    return text if half < 10

    first = norm[0, half]
    second = (norm[half..] || '').gsub(/\s+/, ' ').strip
    
    check_and_strip(text, first, second)
  end

  def check_and_strip(text, first, second)
    return text if second.length < 10

    duplicate_detected?(first, second) ? text[0, text.length / 2].strip : text
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
    content_parts = []
    content_parts << "Current user request: #{user_request}#{format_previous_requests}\n\n"

    if previous_agent_response && !previous_agent_response.strip.empty?
      content_parts << "Final response from previous agent run:\n#{previous_agent_response.strip}\n"
    end

    content_parts.join("\n")
  end

  def build_verification_prompt(req, previous_agent_response = nil)
    user_content = build_verification_user_content(req, previous_agent_response)
    "#{build_verification_system_instruction}\n\n---\n\n#{user_content}"
  end

  def run_verification(model, req, previous_agent_response = nil)
    verification_prompt = build_verification_prompt(req, previous_agent_response)
    start_time = Time.now
    success, output = @agent_executor.run(model, verification_prompt, verification_mode: true)
    duration = Time.now - start_time
    return [false, 'Verification failed', duration] unless success

    verified, desc = parse_res(output.strip)
    [verified, desc || 'Failed', duration]
  end

  def retry_with_fix(model, req)
    fix_prompt = build_fix_prompt(req)
    @display.puts "Retrying #{model} with fix...".blue
    $stdout.puts ''

    success, fix_output = @agent_executor.run(model, fix_prompt)
    return [false, nil, 0, nil] unless success

    verified, desc, review_time = run_verification(model, req, fix_output)
    [verified, desc, review_time, fix_output]
  end

end
