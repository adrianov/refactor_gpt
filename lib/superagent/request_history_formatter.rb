# frozen_string_literal: true

# Formats request text for session history lines (verification, refactor, etc.).
# Used by Superagent to build history entry text without duplicating truncation logic.
module RequestHistoryFormatter
  # Max length for previous-request text stored in session and shown in "Previous requests" prompt.
  PREVIOUS_REQUEST_PROMPT_LEN = 300
  # Preview length for recap sections (Completed/Failed/Queued). Increase to reduce truncation.
  RECAP_PREVIEW_LEN = 120
  # Preview length for queue and running-request lines. Increase to reduce truncation.
  QUEUE_PREVIEW_LEN = 100

  module_function

  def truncated_first_line(req, max_len = PREVIOUS_REQUEST_PROMPT_LEN)
    s = req.to_s.strip
    return nil if s.empty?

    first = s.lines.first&.strip || s
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
    first.to_s.strip.empty? ? "—" : first
  end
end
