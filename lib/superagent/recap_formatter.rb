# frozen_string_literal: true

# Parses and formats agent recap text for display and prompts.
# Recap is split into intro (lines before summary marker) and summary (marker to end).
# Shared by VerificationDisplay and AgentPromptBuilder. Spacing is controlled by constants below.
class RecapFormatter
  SUMMARY_MARKER = /^\s*Summary of (changes?|what changed|what was fixed)\s*:?\s*/i
  # Prompt spacing: increase for less compact summary in the next prompt.
  INTRO_JOIN = "\n\n"                    # Between intro lines
  INTRO_SUMMARY_SEPARATOR = "\n\n"       # Between intro block and summary block

  # Value object: intro_lines (array), summary_lines (array or nil), summary_raw (string or nil).
  # summary_raw is the summary section with original newlines preserved (for display and prompt).
  RecapSections = Struct.new(:intro_lines, :summary_lines, :summary_raw, keyword_init: true)

  def self.parse_recap_sections(text)
    lines = text.to_s.each_line.map(&:chomp)
    summary_idx = lines.index { |l| l =~ SUMMARY_MARKER }
    intro = summary_idx ? lines[0...summary_idx] : lines
    summary_lines = summary_idx ? lines[summary_idx..] : nil
    summary_raw = summary_lines&.join("\n")
    RecapSections.new(intro_lines: intro, summary_lines: summary_lines, summary_raw: summary_raw)
  end

  def self.format_intro_for_prompt(intro_lines)
    intro_lines.to_a.reject(&:empty?).join(INTRO_JOIN)
  end

  def self.format_recap_for_prompt(text)
    sections = parse_recap_sections(text.to_s.strip)
    formatted_intro = format_intro_for_prompt(sections.intro_lines)
    return formatted_intro if sections.summary_raw.nil? || sections.summary_raw.empty?

    formatted_intro + INTRO_SUMMARY_SEPARATOR + sections.summary_raw
  end
end
