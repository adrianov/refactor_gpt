# frozen_string_literal: true

# Assembles the agent prompt: user request, session context, and out-of-scope guard.
class AgentPromptBuilder
  MAX_PREVIOUS_REQUESTS = AgentPromptContext::MAX_PREVIOUS_REQUESTS

  # Agent outputs this when request is out of scope; we then set Failed and skip verification.
  OUT_OF_SCOPE_MARKER = 'FAILED: OUT_OF_SCOPE'

  OUT_OF_SCOPE_INSTRUCTION = "\n\nIf the feature or request is out of scope for this project (e.g. unrelated to the " \
    "project mission, or not a coding task within the project's technologies), do not implement. " \
    "Instead output exactly: #{OUT_OF_SCOPE_MARKER}"

  # Phrase used when instructing the model to follow project rules (e.g. in refactor/verification prompts).
  # Files are attached; do not tell the model to read specific filenames.
  GUIDELINE_REFERENCE_PHRASE = 'Follow the project and user Cursor rules already provided in context.'

  # Phrase used in verification system instruction for how to verify changes.
  # Context is attached; do not instruct the model to read files again.
  VERIFICATION_FILES_PHRASE = "You may run 'git diff' or use the attached context to verify the changes."

  def initialize(session_tracker)
    @session_tracker = session_tracker
    @context = AgentPromptContext.new(session_tracker)
  end

  def wrap_prompt(p, new_session: false, current_request: nil, verification_mode: false,
                  continuation_analysis: nil, fix_stage: false)
    user_content = format_user_request_content(p, continuation_analysis)
    rest = @context.context_parts(new_session, fix_stage: fix_stage).compact.join
    session_desc = continuation_analysis&.dig(:description)
    history = verification_mode ? nil : @context.history_section(
      current_request: current_request, session_description: session_desc
    )
    summary = @context.summary_section(session_description: session_desc)
    base = prompt_parts_ordered(history, summary, user_content, rest, session_desc)
    implementation_prompt?(verification_mode, fix_stage) ? base + OUT_OF_SCOPE_INSTRUCTION : base
  end

  def guidelines_section(always_include: false, fix_stage: false)
    @context.guidelines_section(always_include: always_include, fix_stage: fix_stage)
  end

  def modified_files_section
    @context.modified_files_section
  end

  def non_interactive_notice
    @context.non_interactive_notice
  end

  private

  # Continuation: already-addressed list first, then current (new) request last; otherwise user content first.
  def prompt_parts_ordered(history, summary, user_content, rest, session_desc)
    blocks = [history.to_s, summary.to_s]
    if session_desc && history.to_s.strip != ''
      blocks.join + user_content + rest
    else
      user_content + blocks.join + rest
    end
  end

  # Single place to build the user request block sent to the agent. Prepends CONTINUATION/TAGS/DESCRIPTION when present.
  # If request_text is a classification title (e.g. "TITLE: Classifying to a session"), use a placeholder so the
  # prompt never shows the title as the request.
  def format_user_request_content(request_text, continuation_analysis)
    return request_text.to_s if continuation_analysis.nil? || continuation_analysis.empty?

    text = request_text.to_s.strip
    text = '(current request; see context)' if classification_title_as_request?(text)
    continuation_request_header(continuation_analysis) + "Request to classify (not yet addressed):\n" + text
  end

  def continuation_request_header(analysis)
    cont_value = analysis[:continuation_id] || 'NEW'
    [
      "[#{Time.now.strftime('%H:%M:%S')}] CONTINUATION: #{cont_value}",
      "TAGS: #{format_continuation_tags(analysis[:tags])}",
      format_continuation_description(analysis[:description]),
      ''
    ].compact.join("\n")
  end

  def format_continuation_tags(tags)
    (tags || []).empty? ? 'NONE' : (tags || []).join(', ')
  end

  def format_continuation_description(desc)
    (desc && !desc.to_s.strip.empty?) ? "DESCRIPTION: #{desc}" : nil
  end

  def classification_title_as_request?(text)
    @session_tracker&.classification_title_as_request?(text) == true
  end

  def implementation_prompt?(verification_mode, fix_stage)
    !verification_mode && !fix_stage
  end
end
