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
#
# Summary can appear compact (e.g. "Summary of what was implemented:### 1.") when the agent
# stream sends the header and first list item in one chunk. Normalize via normalize_recap_newlines
# before display and before format_recap_for_prompt so a newline is ensured after the header.
#
# Display: use prepare_recap_for_display(text) as the single entry point for recap text shown to
# the user. Add display-only formatting (e.g. line wrapping for readability) there.
class RecapFormatter
  SUMMARY_PHRASE = 'changes?|what changed|what was fixed|what was implemented'
  SUMMARY_MARKER = /^\s*Summary of (#{SUMMARY_PHRASE})\s*:?\s*/i
  # Prompt: no empty lines between intro lines.
  INTRO_JOIN = "\n"
  INTRO_SUMMARY_SEPARATOR = "\n\n"
  DISPLAY_LINE_WIDTH = 100

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

  # Pattern for compact summary: header (same phrasing as SUMMARY_MARKER) then non-whitespace without newline.
  COMPACT_SUMMARY_HEADER = /(Summary of (?:#{SUMMARY_PHRASE})\s*:?\s*)([^\s\n])/i

  # Single normalization point for recap text. Call before display and before format_recap_for_prompt.
  # Inserts newline after summary header when missing (e.g. "Summary of what was implemented:### 1.").
  def self.normalize_recap_newlines(text)
    text.to_s.gsub(COMPACT_SUMMARY_HEADER, "\\1\n\\2")
  end

  # Single entry point for recap text shown to the user. Use this for display; add readability
  # (e.g. line wrapping) here so prompt formatting stays unchanged.
  def self.prepare_recap_for_display(text)
    wrap_long_lines(normalize_recap_newlines(text.to_s), DISPLAY_LINE_WIDTH)
  end

  def self.wrap_long_lines(text, width)
    text.each_line.map { |line| wrap_line(line.chomp, width) }.join("\n")
  end

  def self.wrap_line(line, width)
    return line if line.length <= width

    words = line.split(/\s/)
    build_wrapped_lines(words, width)
  end

  def self.build_wrapped_lines(words, width)
    lines = []
    current = []
    current_len = 0
    words.each do |word|
      if line_fits?(current_len, current.any?, word.length, width)
        current << word
        current_len += (current.empty? ? word.length : 1 + word.length)
      else
        lines, current, current_len = flush_and_start_line(lines, current, word)
      end
    end
    lines << current.join(' ') if current.any?
    lines.join("\n")
  end

  def self.flush_and_start_line(lines, current, word)
    lines = lines + (current.any? ? [current.join(' ')] : [])
    [lines, [word], word.length]
  end

  def self.line_fits?(current_len, has_words, word_len, width)
    current_len + (has_words ? 1 : 0) + word_len <= width
  end

  def self.format_recap_for_prompt(text)
    normalized = normalize_recap_newlines(recap_text_for_prompt(text))
    sections = parse_recap_sections(normalized)
    intro_part = format_intro_for_prompt(sections.intro_lines)
    summary_part = summary_block_from_text(normalized)
    return intro_part if summary_part.nil? || summary_part.empty?

    intro_part + INTRO_SUMMARY_SEPARATOR + summary_part
  end
end
