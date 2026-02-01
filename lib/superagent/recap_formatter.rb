# frozen_string_literal: true

# Parses and formats agent recap text for display and prompts.
# Recap is split into intro (lines before summary marker) and summary (marker to end).
# Shared by VerificationDisplay and AgentPromptBuilder. Spacing is controlled by constants below.
class RecapFormatter
  SUMMARY_MARKER = /^\s*Summary of (changes?|what changed|what was fixed)\s*:?\s*/i
  # Prompt spacing: increase for less compact summary in the next prompt.
  INTRO_JOIN = "\n\n"                    # Between intro lines
  INTRO_SUMMARY_SEPARATOR = "\n\n"       # Between intro block and summary block
  SUMMARY_LINE_JOIN = "\n\n"            # Between summary lines (blank line for readability)

  def self.parse_recap_sections(text)
    lines = text.to_s.each_line.map(&:chomp)
    summary_idx = lines.index { |l| l =~ SUMMARY_MARKER }
    intro = summary_idx ? lines[0...summary_idx] : lines
    summary = summary_idx ? lines[summary_idx..] : nil
    [intro, summary]
  end

  def self.format_intro_for_prompt(intro_lines)
    intro_lines.to_a.reject(&:empty?).join(INTRO_JOIN)
  end

  def self.format_summary_for_prompt(summary_lines)
    summary_lines.to_a.join(SUMMARY_LINE_JOIN)
  end

  def self.format_recap_for_prompt(text)
    intro, summary = parse_recap_sections(text.to_s.strip)
    formatted_intro = format_intro_for_prompt(intro)
    return formatted_intro if summary.nil? || summary.empty?

    formatted_intro + INTRO_SUMMARY_SEPARATOR + format_summary_for_prompt(summary)
  end
end
