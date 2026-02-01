# frozen_string_literal: true

# Parses and formats agent recap text for display and prompts.
# Recap has two parts: intro (lines before summary marker) and summary block (marker to end).
# Intro is formatted for prompt (spacing controlled by INTRO_JOIN); summary block can be used raw.
# Shared by VerificationDisplay and AgentPromptBuilder.
class RecapFormatter
  SUMMARY_MARKER = /^\s*Summary of (changes?|what changed|what was fixed)\s*:?\s*/i
  # Prompt: no empty lines between intro lines.
  INTRO_JOIN = "\n"
  INTRO_SUMMARY_SEPARATOR = "\n\n"

  # Value object: intro_lines (array), summary_lines (array or nil), summary_block (string or nil).
  # summary_block is the summary section and everything after (for display and prompt).
  RecapSections = Struct.new(:intro_lines, :summary_lines, :summary_block, keyword_init: true)

  def self.parse_recap_sections(text)
    lines = text.to_s.each_line.map(&:chomp)
    summary_idx = lines.index { |l| l =~ SUMMARY_MARKER }
    intro = summary_idx ? lines[0...summary_idx] : lines
    summary_lines = summary_idx ? lines[summary_idx..] : nil
    summary_block = summary_lines&.join("\n")
    RecapSections.new(intro_lines: intro, summary_lines: summary_lines, summary_block: summary_block)
  end

  # Returns the summary block as raw substring (no line-by-line processing). Use for unprocessed prompt.
  def self.summary_block_from_text(text)
    lines_with_newlines = text.to_s.each_line.to_a
    idx = lines_with_newlines.index { |l| l.chomp =~ SUMMARY_MARKER }
    idx ? lines_with_newlines[idx..].join : nil
  end

  def self.format_intro_for_prompt(intro_lines)
    intro_lines.to_a.reject(&:empty?).join(INTRO_JOIN)
  end

  def self.format_recap_for_prompt(text)
    stripped = text.to_s.strip
    sections = parse_recap_sections(stripped)
    intro_part = format_intro_for_prompt(sections.intro_lines)
    summary_part = summary_block_from_text(stripped)
    return intro_part if summary_part.nil? || summary_part.empty?

    intro_part + INTRO_SUMMARY_SEPARATOR + summary_part
  end
end
