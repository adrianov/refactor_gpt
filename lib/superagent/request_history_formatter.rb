# frozen_string_literal: true

# Formats request text for session history lines (verification, refactor, etc.).
# Used by Superagent to build history entry text without duplicating truncation logic.
# Display preview lengths (recap and queue): increase RECAP_PREVIEW_LEN / QUEUE_PREVIEW_LEN for less compact previews.
module RequestHistoryFormatter
  # Max length for previous-request text stored in session and shown in "Previous requests" prompt.
  PREVIOUS_REQUEST_PROMPT_LEN = 300
  # Recap sections (Completed/Failed/Queued): one-line preview max length.
  RECAP_PREVIEW_LEN = 200
  # Queue and running-request lines: one-line preview max length.
  QUEUE_PREVIEW_LEN = 160

  module_function

  def truncated_first_line(req, max_len = PREVIOUS_REQUEST_PROMPT_LEN)
    s = RequestPreparer.normalized_request_text(req)
    return nil if s.empty?

    first = (s.lines.first ? s.lines.first.to_s.strip : nil) || s
    first = "#{first[0..(max_len - 1)]}..." if first.length > max_len
    first
  end

  def recap_preview(req)
    truncated_first_line(req, RECAP_PREVIEW_LEN) || ''
  end

  def queue_preview(req)
    truncated_first_line(req, QUEUE_PREVIEW_LEN) || ''
  end

  def verification_entry(req)
    first = truncated_first_line(req)
    first ? "Verification: #{first}" : "Verification"
  end

  def refactor_entry(req)
    first = truncated_first_line(req)
    (first.nil? || first.to_s.strip.empty?) ? "—" : first
  end
end
