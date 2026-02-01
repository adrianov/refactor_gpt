# frozen_string_literal: true

# Parses and formats agent recap text for display and prompts.
# Recap is split into intro (lines before summary marker) and summary (marker to end).
# Intro is compact (no blank lines); summary keeps newlines. Shared by VerificationDisplay and AgentPromptBuilder.
# To show less compact prompt summary: use a longer INTRO_JOIN (e.g. "\n\n") in format_intro_compact.
class RecapFormatter
  SUMMARY_MARKER = /^\s*Summary of (changes?|what changed|what was fixed)\s*:?\s*/i
  # Separator between intro lines when formatting for prompt; "\n" = compact, "\n\n" = less compact.
  INTRO_JOIN = "\n\n"

  def self.parse_recap_sections(text)
    lines = text.to_s.each_line.map(&:chomp)
    summary_idx = lines.index { |l| l =~ SUMMARY_MARKER }
    intro = summary_idx ? lines[0...summary_idx] : lines
    summary = summary_idx ? lines[summary_idx..] : nil
    [intro, summary]
  end

  def self.format_intro_compact(intro_lines)
    intro_lines.to_a.reject(&:empty?).join(INTRO_JOIN)
  end

  def self.format_summary_preserve_newlines(summary_lines)
    summary_lines.to_a.join("\n")
  end

  def self.format_recap_for_prompt(text)
    intro, summary = parse_recap_sections(text.to_s.strip)
    compact_intro = format_intro_compact(intro)
    return compact_intro if summary.nil? || summary.empty?

    compact_intro + "\n\n" + format_summary_preserve_newlines(summary)
  end
end
