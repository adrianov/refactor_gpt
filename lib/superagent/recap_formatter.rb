# frozen_string_literal: true

# Parses and formats agent recap text for display and prompts.
# Recap has two parts: intro (lines before summary marker) and summary block (marker to end).
# Intro is formatted for prompt (spacing controlled by INTRO_JOIN); summary block can be used raw.
# Shared by VerificationDisplay and AgentPromptBuilder.
#
# Summary block sources (current_agent_output must not be compacted):
# - summary_block_from_text(text): raw substring from marker to end; preserves blank lines.
#   Use for prompt and display when argument is raw recap (e.g. current_agent_output).
# - RecapSections#summary_block: built from summary_lines.join("\n"); compact (blank lines lost).
#   Use only when line array is needed; do not use for current_agent_output.
class RecapFormatter
  SUMMARY_MARKER = /^\s*Summary of (changes?|what changed|what was fixed)\s*:?\s*/i
  # Prompt: no empty lines between intro lines.
  INTRO_JOIN = "\n"
  INTRO_SUMMARY_SEPARATOR = "\n\n"

  # Value object: intro_lines (array), summary_lines (array or nil), summary_block (string or nil).
  # summary_block is compact (join "\n"; blank lines lost). For preserved formatting use summary_block_from_text.
  RecapSections = Struct.new(:intro_lines, :summary_lines, :summary_block, keyword_init: true)

  def self.parse_recap_sections(text)
    lines = text.to_s.each_line.map(&:chomp)
    summary_idx = lines.index { |l| l =~ SUMMARY_MARKER }
    intro = summary_idx ? lines[0...summary_idx] : lines
    summary_lines = summary_idx ? lines[summary_idx..] : nil
    summary_block = summary_lines&.join("\n")
    RecapSections.new(intro_lines: intro, summary_lines: summary_lines, summary_block: summary_block)
  end

  # Raw substring from summary marker to end (no line-by-line processing). Use for prompt/display when preserving.
  def self.summary_block_from_text(text)
    lines_with_newlines = text.to_s.each_line.to_a
    idx = lines_with_newlines.index { |l| l.chomp =~ SUMMARY_MARKER }
    idx ? lines_with_newlines[idx..].join : nil
  end

  def self.format_intro_for_prompt(intro_lines)
    intro_lines.to_a.reject(&:empty?).join(INTRO_JOIN)
  end

  # Single normalization point for recap before prompt. Preserves newlines (e.g. leading/trailing from JSON result).
  def self.recap_text_for_prompt(text)
    text.to_s
  end

  def self.format_recap_for_prompt(text)
    normalized = recap_text_for_prompt(text)
    sections = parse_recap_sections(normalized)
    intro_part = format_intro_for_prompt(sections.intro_lines)
    summary_part = summary_block_from_text(normalized)
    return intro_part if summary_part.nil? || summary_part.empty?

    intro_part + INTRO_SUMMARY_SEPARATOR + summary_part
  end
end
