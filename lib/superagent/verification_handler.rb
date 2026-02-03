# frozen_string_literal: true

# Handles verification prompts and response parsing. After run_verification, retry_with_fix, or run_refactor,
# callers read the last outcome via verified, desc, review_time, call_failed, retryable, raw_output,
# fix_output, refactor_output.
class VerificationHandler
  include AgentsFileHandler

  # Refactor-stage prompt: intro line. Refactor runs after implementation.
  REFACTOR_STEP_INTRO = 'Refactor changed files: improve structure (e.g. split or simplify) while preserving behavior.'
  # Refactor-stage "You must:" bullets (guideline added in build_refactor_prompt). Edit wording for humans/LLMs.
  REFACTOR_STEP_REQUIREMENTS = [
    'Apply changes that make code easier to edit and understand for both humans and LLMs: ' \
    'improve structure, remove duplication, use clear and literal names, keep methods and ' \
    'blocks small and focused, prefer explicit logic over clever or implicit code.',
    'Preserve all existing behavior; do not add or change functionality.'
  ].freeze

  # Shotgun Surgery refactor: triggered when one business rule change touched more than 6 files (after implementation).
  SHOTGUN_REFACTOR_PROMPT = <<~HEREDOC.freeze
    SYSTEM ROLE: ARCHITECTURAL REFACTORING AGENT

    The user request has already been implemented and has triggered a "Shotgun Surgery" alert: the implementation required edits across %<file_count>s files. This indicates high coupling and poor encapsulation. The specific affected file names are listed in the "Affected files" section below.

    YOUR OBJECTIVE:
    Refactor the already-implemented code to centralize the logic that was spread across these files, so that future changes to this rule would touch fewer files (ideally one).

    CONSTRAINTS:
    1. Preserve all current behavior; do not add or remove functionality.
    2. Identify the "Gravity Center": Where should this logic naturally live (e.g., a new Service, a shared Base Class, or a Utility module)?
    3. Use the "Least Change" principle: Refactor only what is necessary to reduce the number of files affected by this specific rule.

    INSTRUCTIONS:
    1. Analyze: Look at the commonalities in the code that was added/edited across these %<file_count>s files.
    2. Abstract: Create a single source of truth (e.g., a new method or module instead of repeating logic in many places).
    3. Execute: Step A: Create the new abstraction. Step B: Update the affected files to call this new abstraction. Step C: Confirm that future changes to this rule would now only require editing ONE file.

    OUTPUT:
    Provide the code for the new abstraction and the updated call-sites in the affected files.

    This agent runs in non-interactive mode. Make all decisions autonomously and execute tasks directly without requesting user input. Proceed with implementation based on the available context.
  HEREDOC

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

  def build_refactor_prompt(req, triggering_files: [], shotgun_file_count: nil, shotgun_file_paths: nil)
    if shotgun_file_count
      build_shotgun_refactor_prompt(req, shotgun_file_count, shotgun_file_paths)
    else
      build_line_count_refactor_prompt(req, triggering_files)
    end
  end

  def build_shotgun_refactor_prompt(req, file_count, file_paths)
    body = format(self.class::SHOTGUN_REFACTOR_PROMPT, file_count: file_count)
    parts = ["User request (already implemented): #{to_utf8(req)}\n\n", body]
    list = (file_paths && file_paths.any?) ? file_paths.map { |p| "  - #{p}" }.join("\n") : nil
    parts << "\nAffected files:\n#{list || '  (see implementation diff)'}"
    parts.join("\n")
  end

  def build_line_count_refactor_prompt(req, triggering_files)
    a, b = self.class::REFACTOR_STEP_REQUIREMENTS
    guideline = AgentPromptBuilder::GUIDELINE_REFERENCE_PHRASE
    bullets = "- #{a}\n- #{guideline}\n- #{b}"
    trigger_blurb = format_refactor_trigger_blurb(triggering_files)
    <<~HEREDOC
      User request (already implemented): #{to_utf8(req)}

      #{self.class::REFACTOR_STEP_INTRO}
      #{trigger_blurb}

      You must:
      #{bullets}
    HEREDOC
  end

  # Describes which changed files triggered this refactor step and why (line count >= threshold).
  def format_refactor_trigger_blurb(triggering_files)
    return '' if triggering_files.nil? || triggering_files.empty?

    lines = triggering_files.map do |e|
      "  - #{e[:path]} (#{e[:lines]} lines; refactor threshold for this file type is #{e[:limit]} lines)"
    end
    intro = 'This refactor step was triggered because the following changed file(s) exceed the project ' \
            "line-count thresholds:\n#{lines.join("\n")}\n"
    intro + "Prioritize refactoring these files (e.g. split or simplify) while preserving behavior.\n"
  end

  # Returns [verified, desc] or [false, res, :incomplete] when response has no YES/NO verdict.
  def parse_res(res)
    return [false, res] if res.nil? || res.to_s.strip.empty?

    line_info = extract_final_verdict_line(res)
    return [false, res, :incomplete] unless line_info

    line_info[:verdict] == :no ? parse_no_res(line_info[:text]) : parse_yes_res(line_info[:text])
  end

  # Returns verdict from the first line that starts with "YES: " or "NO: " (after optional whitespace).
  # When line-based lookup finds nothing, whole_text_verdict handles output where the newline before
  # YES/NO was lost so the verdict appears mid-line (e.g. "...**YES: The changes...**").
  def extract_final_verdict_line(text)
    line_based_verdict(text) || whole_text_verdict(text)
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

      Multiple requests in one run:
      The implementation may have addressed multiple requests in a single run. When "Other requests that may have been in scope" are listed, treat changes that clearly fulfill those requests as requested. Only respond NO when the diff introduces changes that are not requested by the current request nor by any of the other listed requests. Do not treat changes that fulfill other listed requests as unrequested.

      Available information:
      - Current user request
      - Other requests that may have been in scope for this implementation (if listed)
      - Final summary/response from the previous agent run that attempted to implement the feature

      Verification approach:
      - Review the previous agent's response to understand what was implemented
      - #{AgentPromptBuilder::VERIFICATION_FILES_PHRASE}
      - Check if the changes address the current user request (and, when listed, other in-scope requests)
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

  # previous_agent_response: NDJSON type=result content when present (current_recap_text), else full output.
  # additional_requests: optional array of { type:, text: } (other requests in scope for this implementation).
  def build_verification_user_content(user_request, previous_agent_response, additional_requests: nil)
    req_utf8 = to_utf8(user_request)
    prev_embedded = agent_response_for_verification_content(previous_agent_response)
    content_parts = []
    content_parts << "Current user request: #{req_utf8}\n\n"
    other_section = format_other_requests_section(additional_requests)
    content_parts << "#{other_section}\n\n" if other_section && !other_section.empty?
    if prev_embedded && !prev_embedded.empty?
      content_parts << "Final response from previous agent run:\n#{prev_embedded}\n"
    end
    content_parts.map { |p| to_utf8(p) }.join("\n")
  end

  def format_other_requests_section(additional_requests)
    return nil if additional_requests.nil? || additional_requests.empty?

    lines = additional_requests.each_with_index.map do |req, i|
      text = RequestHistoryFormatter.truncated_first_line(req[:text]) || req[:text].to_s.strip
      type = req[:type] || 'implementation'
      "  #{i + 1}. (#{type}) #{text}"
    end
    header = 'Other requests that may have been in scope for this implementation (same as in implementation prompt):'
    "#{header}\n#{lines.join("\n")}"
  end

  # Single normalization point for previous agent response in verification. Preserves newlines (no strip).
  def agent_response_for_verification_content(previous_agent_response)
    to_utf8(previous_agent_response).to_s
  end

  def build_verification_prompt(req, previous_agent_response = nil, additional_requests: nil)
    user_content = build_verification_user_content(req, previous_agent_response, 
additional_requests: additional_requests)
    notice = @agent_executor.non_interactive_notice
    guidelines = @agent_executor.guidelines_section(always_include: true)
    "#{build_verification_system_instruction}\n\n---\n\n#{user_content}\n\n---\n\n#{notice}\n\n#{guidelines}"
  end

  def run_verification(model, req, previous_agent_response = nil, additional_requests: nil)
    verification_prompt = build_verification_prompt(req, previous_agent_response, 
additional_requests: additional_requests)
    start_time = Time.now
    success, output, reason = @agent_executor.run(model, verification_prompt, verification_mode: true,
                                                  current_request: req)
    @review_time = Time.now - start_time
    unless success
      set_verification_failure(output, reason)
      return
    end
    parsed = parse_res(verification_response_for_parsing(output))
    if parsed[2] == :incomplete
      set_verification_failure(output, :no_verdict)
    else
      set_verification_success(parsed)
    end
  end

  def set_verification_failure(output, reason)
    normalized = verification_response_for_parsing(output)
    @verified = false
    incomplete = incomplete_verification_output?(normalized, reason)
    @desc = incomplete ? 'Verification call failed (no response)' : normalized.lines.first.to_s.strip
    @call_failed = true
    @retryable = (reason == :recoverable) || incomplete
    @raw_output = output.to_s
    @fix_output = nil
    @refactor_output = nil
  end

  def incomplete_verification_output?(normalized, reason)
    return true if normalized.nil? || normalized.to_s.strip.empty?
    return true if reason == :no_verdict

    RunFailureClassifier.stream_json_init?(normalized)
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

  def retry_with_fix(model, req, additional_requests: nil)
    fix_prompt = build_fix_prompt(req)
    @display.puts "Retrying #{model} with fix...".blue
    $stdout.puts ''

    success, fix_out = @agent_executor.run(model, fix_prompt, current_request: req, fix_stage: true)
    unless success
      @verified = false
      @desc = nil
      @review_time = 0
      @fix_output = nil
      @refactor_output = nil
      return
    end

    run_verification(model, req, fix_out, additional_requests: additional_requests)
    @fix_output = fix_out
    @refactor_output = nil
  end

  def run_refactor(model, req, triggering_files: [], shotgun_file_count: nil, shotgun_file_paths: nil)
    @refactor_output = nil
    refactor_prompt = build_refactor_prompt(req, triggering_files: triggering_files,
                                            shotgun_file_count: shotgun_file_count,
                                            shotgun_file_paths: shotgun_file_paths)
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

  def line_based_verdict(text)
    text.to_s.each_line do |line|
      match = line.match(/\A\s*(YES|NO):\s*(.*)\z/im)
      next unless match

      return { verdict: match[1].casecmp('no').zero? ? :no : :yes, text: line.to_s.strip }
    end
    nil
  end

  # Fallback when newline before YES/NO was lost: match YES/NO only after sentence-like boundary
  # (period, **, or newline) so ".**YES: ..." is accepted but "I checked and YES: ..." is not.
  def whole_text_verdict(text)
    s = text.to_s
    m = s.match(/(?:\.\s*|\*\*\s*|\n\s*)(YES|NO)\s*:\s*(.*)/im)
    return nil unless m

    { verdict: m[1].casecmp('no').zero? ? :no : :yes, text: "#{m[1]}: #{m[2]}".strip }
  end

  def to_utf8(str)
    return '' if str.nil?
    s = str.to_s.dup
    s.force_encoding(Encoding::UTF_8)
    s.valid_encoding? ? s : s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
  end

  private :verification_response_for_parsing, :line_based_verdict, :whole_text_verdict, :to_utf8,
          :incomplete_verification_output?, :format_other_requests_section

end
