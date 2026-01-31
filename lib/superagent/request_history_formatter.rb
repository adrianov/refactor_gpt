# frozen_string_literal: true

# Formats request text for session history lines (verification, refactor, etc.).
# Used by Superagent to build history entry text without duplicating truncation logic.
module RequestHistoryFormatter
  # Max length for previous-request text stored in session and shown in "Previous requests" prompt.
  PREVIOUS_REQUEST_PROMPT_LEN = 300

  module_function

  def truncated_first_line(req, max_len = PREVIOUS_REQUEST_PROMPT_LEN)
    s = req.to_s.strip
    return nil if s.empty?

    first = s.lines.first&.strip || s
    first = "#{first[0..(max_len - 1)]}..." if first.length > max_len
    first
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
