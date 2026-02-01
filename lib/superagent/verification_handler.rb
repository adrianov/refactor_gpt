# frozen_string_literal: true

# Handles verification prompts and response parsing. After run_verification, retry_with_fix, or run_refactor,
# callers read the last outcome via verified, desc, review_time, call_failed, retryable, raw_output,
# fix_output, refactor_output.
class VerificationHandler
  include AgentsFileHandler

  # Refactor-stage prompt: intro line. Edit wording here when improving refactor-stage instruction.
  REFACTOR_STEP_INTRO = 'Refactor the codebase so that implementing this request will be straightforward. ' \
    'Do not implement the request yet.'
  # Refactor-stage "You must:" bullets (guideline added in build_refactor_prompt). Edit wording for humans/LLMs.
  REFACTOR_STEP_REQUIREMENTS = [
    'Apply changes that make code easier to edit and understand for both humans and LLMs: ' \
    'improve structure, remove duplication, use clear and literal names, keep methods and ' \
    'blocks small and focused, prefer explicit logic over clever or implicit code.',
    'Preserve all existing behavior; do not add or change functionality.'
  ].freeze

  attr_reader :verified, :desc, :review_time, :call_failed, :retryable, :raw_output, :fix_output, :refactor_output

  def initialize(display, agent_executor)
    @display = display
    @agent_executor = agent_executor
  end

  def build_fix_prompt(req)
    <<~HEREDOC
      Original request: #{to_utf8(req)}

      The previous attempt failed. Please fix the implementation.

      Review the codebase and make the necessary corrections.
    HEREDOC
  end

  def build_refactor_prompt(req)
    a, b = self.class::REFACTOR_STEP_REQUIREMENTS
    guideline = AgentPromptBuilder::GUIDELINE_REFERENCE_PHRASE
    bullets = "- #{a}\n- #{guideline}\n- #{b}"
    <<~HEREDOC
      User request (to be implemented in the next step): #{to_utf8(req)}

      #{self.class::REFACTOR_STEP_INTRO}

      You must:
      #{bullets}
    HEREDOC
  end

  def parse_res(res)
    return [false, res] if res.nil? || res.to_s.strip.empty?

    line_info = extract_final_verdict_line(res)
    return [false, res] unless line_info

    line_info[:verdict] == :no ? parse_no_res(line_info[:text]) : parse_yes_res(line_info[:text])
  end

  # Only lines that start with YES: or NO: (after optional whitespace) are treated as the verdict.
  def extract_final_verdict_line(text)
    text.to_s.each_line do |line|
      match = line.match(/\A\s*(YES|NO):\s*(.*)\z/im)
      next unless match

      return { verdict: match[1].casecmp('no').zero? ? :no : :yes, text: line.to_s.strip }
    end
    nil
  end

  def parse_no_res(line)
    m = line.match(/\A\s*NO:\s*(.*)\z/im)
    return [false, 'Failed'] unless m

    desc = m[1].to_s.strip
    [false, desc.empty? ? 'Failed' : remove_duplicates(desc)]
  end

  def parse_yes_res(line)
    m = line.match(/\A\s*YES:\s*(.*)\z/im)
    return [true, 'Passed'] unless m

    desc = m[1].to_s.strip
    [true, desc.empty? ? 'Passed' : desc]
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

    duplicate_detected?(first, second) ? text.to_s[0, text.length / 2].to_s.strip : text
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
      - Final summary/response from the previous agent run that attempted to implement the feature

      Verification approach:
      - Review the previous agent's response to understand what was implemented
      - #{AgentPromptBuilder::VERIFICATION_FILES_PHRASE}
      - Check if the changes address the user's request
      - Look for potential bugs, regressions, or missing functionality
      - Verify code quality and adherence to project guidelines
      - You MUST respond NO when the edited code has obvious quality issues (e.g. violates DRY, SOLID, or YAGNI)

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

  # previous_agent_response: raw agent output (e.g. current_agent_output); do not compact.
  def build_verification_user_content(user_request, previous_agent_response)
    req_utf8 = to_utf8(user_request)
    prev_embedded = agent_response_for_verification_content(previous_agent_response)
    content_parts = []
    content_parts << "Current user request: #{req_utf8}\n\n"
    if prev_embedded && !prev_embedded.empty?
      content_parts << "Final response from previous agent run:\n#{prev_embedded}\n"
    end
    content_parts.map { |p| to_utf8(p) }.join("\n")
  end

  # Single normalization point for previous agent response in verification. Preserves newlines (no strip).
  def agent_response_for_verification_content(previous_agent_response)
    to_utf8(previous_agent_response).to_s
  end

  def build_verification_prompt(req, previous_agent_response = nil)
    user_content = build_verification_user_content(req, previous_agent_response)
    notice = @agent_executor.non_interactive_notice
    guidelines = @agent_executor.guidelines_section(always_include: true)
    "#{build_verification_system_instruction}\n\n---\n\n#{user_content}\n\n---\n\n#{notice}\n\n#{guidelines}"
  end

  def run_verification(model, req, previous_agent_response = nil)
    verification_prompt = build_verification_prompt(req, previous_agent_response)
    start_time = Time.now
    success, output, reason = @agent_executor.run(model, verification_prompt, verification_mode: true,
                                                  current_request: req)
    @review_time = Time.now - start_time
    unless success
      set_verification_failure(output, reason)
      return
    end
    set_verification_success(parse_res(verification_response_for_parsing(output)))
  end

  def set_verification_failure(output, reason)
    normalized = verification_response_for_parsing(output)
    @verified = false
    blank = normalized.nil? || normalized.to_s.strip.empty?
    @desc = blank ? 'Verification call failed (no response)' : normalized.lines.first.to_s.strip
    @call_failed = true
    @retryable = reason == :recoverable
    @raw_output = output.to_s
    @fix_output = nil
    @refactor_output = nil
  end

  def set_verification_success(parsed)
    parsed_verified, parsed_desc = parsed
    @verified = parsed_verified
    @desc = parsed_desc || 'Failed'
    @call_failed = false
    @retryable = false
    @raw_output = nil
    @fix_output = nil
    @refactor_output = nil
  end

  def finalize_call_failed(verified, desc, review_time, raw_output)
    @verified = verified
    @desc = desc
    @review_time = review_time
    @raw_output = raw_output
    @call_failed = true
    @retryable = false
    @fix_output = nil
    @refactor_output = nil
  end

  def retry_with_fix(model, req)
    fix_prompt = build_fix_prompt(req)
    @display.puts "Retrying #{model} with fix...".blue
    $stdout.puts ''

    success, fix_out = @agent_executor.run(model, fix_prompt, current_request: req)
    unless success
      @verified = false
      @desc = nil
      @review_time = 0
      @fix_output = nil
      @refactor_output = nil
      return
    end

    run_verification(model, req, fix_out)
    @fix_output = fix_out
    @refactor_output = nil
  end

  def run_refactor(model, req)
    @refactor_output = nil
    refactor_prompt = build_refactor_prompt(req)
    @display.puts "Refactoring: #{model}...".blue
    $stdout.puts ''

    success, refactor_out = @agent_executor.run(model, refactor_prompt, current_request: req, new_session: true)
    return false unless success

    @refactor_output = refactor_out
    true
  end

  # Single normalization point for verification run output before parsing and display.
  # Do not strip: newlines must be preserved so line-start "YES: " / "NO: " is detected correctly.
  def verification_response_for_parsing(output)
    output.to_s
  end

  def to_utf8(str)
    return '' if str.nil?
    s = str.to_s.dup
    s.force_encoding(Encoding::UTF_8)
    s.valid_encoding? ? s : s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
  end

  private :verification_response_for_parsing, :to_utf8

end
