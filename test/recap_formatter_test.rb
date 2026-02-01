# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/loader'

class TestRecapFormatter < Minitest::Test
  def test_parse_recap_sections_returns_struct
    text = "Intro line.\n\nSummary of changes:\n- Item one\n- Item two"
    sections = RecapFormatter.parse_recap_sections(text)
    assert_equal RecapFormatter::RecapSections, sections.class
    assert_equal ['Intro line.', ''], sections.intro_lines
    assert_equal ['Summary of changes:', '- Item one', '- Item two'], sections.summary_lines
    assert_equal "Summary of changes:\n- Item one\n- Item two", sections.summary_raw
  end

  def test_parse_recap_sections_no_summary_returns_nil_summary
    text = "Only intro.\nNo summary marker here."
    sections = RecapFormatter.parse_recap_sections(text)
    assert_nil sections.summary_lines
    assert_nil sections.summary_raw
    assert_equal ['Only intro.', 'No summary marker here.'], sections.intro_lines
  end

  def test_format_recap_for_prompt_includes_intro_and_summary
    text = "Intro.\n\nSummary of changes:\n- A\n- B"
    out = RecapFormatter.format_recap_for_prompt(text)
    assert_match(/Intro\./, out)
    assert_match(/Summary of changes:/, out)
    assert_match(/- A/, out)
    assert_match(/- B/, out)
  end

  def test_summary_raw_preserves_newlines
    text = "Intro.\n\nSummary of changes:\n**File** — method\n- Bullet one.\n- Bullet two."
    sections = RecapFormatter.parse_recap_sections(text)
    assert_equal "Summary of changes:\n**File** — method\n- Bullet one.\n- Bullet two.", sections.summary_raw
    assert_includes sections.summary_raw, "\n**File**"
    assert_includes sections.summary_raw, "\n- Bullet one."
  end

  def test_format_recap_for_prompt_does_not_remove_summary_newlines
    text = <<~TEXT.strip
      Intro line.

      Summary of changes:
      **lib/context_window.rb** — tokens_for_intersection
      - Compute median.
      - If median < 2, return unchanged.
    TEXT
    out = RecapFormatter.format_recap_for_prompt(text)
    summary_part = out.split(RecapFormatter::INTRO_SUMMARY_SEPARATOR).last
    assert_includes summary_part, "\n**lib/context_window.rb**",
                    'Summary must keep newline before file line'
    assert_includes summary_part, "\n- Compute median.",
                    'Summary must keep newline before bullet'
    assert_includes summary_part, "\n- If median",
                    'Summary must keep newline before second bullet'
  end
end
