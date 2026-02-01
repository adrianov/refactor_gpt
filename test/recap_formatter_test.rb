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
    assert_equal "Summary of changes:\n- Item one\n- Item two", sections.summary_block
  end

  def test_parse_recap_sections_no_summary_returns_nil_summary
    text = "Only intro.\nNo summary marker here."
    sections = RecapFormatter.parse_recap_sections(text)
    assert_nil sections.summary_lines
    assert_nil sections.summary_block
    assert_equal ['Only intro.', 'No summary marker here.'], sections.intro_lines
  end

  def test_summary_marker_matches_what_was_implemented
    text = "Intro.\nSummary of what was implemented:\n- Item one"
    sections = RecapFormatter.parse_recap_sections(text)
    assert sections.summary_lines, 'Summary block should be detected for "what was implemented"'
    assert_equal ['Summary of what was implemented:', '- Item one'], sections.summary_lines
  end

  def test_normalize_recap_newlines_inserts_newline_after_compact_header
    compact = "Summary of what was implemented:### 1. **Superagent**"
    normalized = RecapFormatter.normalize_recap_newlines(compact)
    assert_includes normalized, "Summary of what was implemented:\n###"
    sections = RecapFormatter.parse_recap_sections(normalized)
    assert sections.summary_lines
    assert_equal 'Summary of what was implemented:', sections.summary_lines.first
    assert sections.summary_lines[1].start_with?('###')
  end

  def test_prepare_recap_for_display_normalizes_and_wraps
    compact = "Summary of what was implemented:### 1."
    out = RecapFormatter.prepare_recap_for_display(compact)
    assert_includes out, "Summary of what was implemented:\n###"
    long = 'a ' * 60
    wrapped = RecapFormatter.prepare_recap_for_display(long)
    wrapped.lines.each { |l| assert l.chomp.length <= RecapFormatter::DISPLAY_LINE_WIDTH, 'Line should be wrapped' }
    assert wrapped.lines.count > 1, 'Long line should be split into multiple'
  end

  def test_format_recap_for_prompt_includes_intro_and_summary
    text = "Intro.\n\nSummary of changes:\n- A\n- B"
    out = RecapFormatter.format_recap_for_prompt(text)
    assert_match(/Intro\./, out)
    assert_match(/Summary of changes:/, out)
    assert_match(/- A/, out)
    assert_match(/- B/, out)
  end

  def test_format_recap_for_prompt_intro_has_no_blank_lines
    text = "Line one.\n\nLine two.\n\nSummary of changes:\n- A"
    out = RecapFormatter.format_recap_for_prompt(text)
    intro_part = out.split(RecapFormatter::INTRO_SUMMARY_SEPARATOR, 2).first
    refute_match(/\n\n/, intro_part, 'Intro part must have no empty lines between items')
    assert_includes intro_part, "Line one.\nLine two."
  end

  def test_summary_block_preserves_newlines
    text = "Intro.\n\nSummary of changes:\n**File** — method\n- Bullet one.\n- Bullet two."
    sections = RecapFormatter.parse_recap_sections(text)
    assert_equal "Summary of changes:\n**File** — method\n- Bullet one.\n- Bullet two.", sections.summary_block
    assert_includes sections.summary_block, "\n**File**"
    assert_includes sections.summary_block, "\n- Bullet one."
  end

  def test_summary_block_from_text_preserves_blank_lines
    text = "Intro.\nSummary of changes:\n\nPara one.\n\nPara two."
    raw = RecapFormatter.summary_block_from_text(text)
    assert raw
    assert_includes raw, "\n\nPara one", 'Blank line before Para one'
    assert_includes raw, "\n\nPara two", 'Blank line before Para two'
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
    summary_part = out.split(RecapFormatter::INTRO_SUMMARY_SEPARATOR, 2).last
    assert_includes summary_part, "\n**lib/context_window.rb**",
                    'Summary must keep newline before file line'
    assert_includes summary_part, "\n- Compute median.",
                    'Summary must keep newline before bullet'
    assert_includes summary_part, "\n- If median",
                    'Summary must keep newline before second bullet'
  end
end
