#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/loader"

class TestVerificationParsing < Minitest::Test
  def setup
    @handler = VerificationHandler.new(Display.new, nil)
  end

  def test_simple_yes_with_description
    assert_parse('YES: All features implemented correctly', true, /features implemented/)
  end

  def test_simple_no_with_description
    assert_parse('NO: Missing email validation', false, /email validation/)
  end

  def test_yes_bold_markdown_not_at_line_start
    verified, _desc = @handler.parse_res('**YES**: Feature is complete')
    assert_equal false, verified
  end

  def test_no_italic_not_at_line_start
    verified, _desc = @handler.parse_res('*NO*: Tests are failing')
    assert_equal false, verified
  end

  def test_yes_at_line_start
    assert_parse('YES: Feature is complete', true, /Feature is complete/)
  end

  def test_no_at_line_start
    assert_parse('NO: Tests are failing', false, /Tests are failing/)
  end

  def test_lowercase_yes
    assert_parse('yes: everything works', true, /everything works/)
  end

  def test_uppercase_no
    assert_parse('NO: BUGS FOUND', false, /BUGS FOUND/)
  end

  def test_yes_without_colon_at_line_start
    verified, _desc = @handler.parse_res('YES All tests pass')
    assert_equal false, verified
  end

  def test_no_without_colon_at_line_start
    verified, _desc = @handler.parse_res('NO Implementation incomplete')
    assert_equal false, verified
  end

  def test_no_line_then_yes_line
    assert_parse("NO: Issues found\nYES: but minor", false, /Issues found/)
  end

  def test_yes_line_then_no_line
    assert_parse("YES: Works well\nNO: with caveats", true, /Works well/)
  end

  def test_empty_response
    verified, _desc = @handler.parse_res('')
    assert_equal false, verified
  end

  def test_no_yes_or_no
    verified, _desc = @handler.parse_res('The code looks good')
    assert_equal false, verified
  end

  def test_yes_mid_line_does_not_count
    verified, _desc = @handler.parse_res('I checked and YES: it works')
    assert_equal false, verified
  end

  def test_second_line_yes_counts
    assert_parse("Preamble text\nYES: it works", true, /it works/)
  end

  def test_multiline_yes
    assert_parse("YES: Implementation is complete\nAll tests passing", true, /Implementation is complete/)
  end

  def test_multiline_no
    assert_parse("NO: Found several issues\n1. Missing validation\n2. No tests", false, /Found several issues/)
  end

  def test_yes_with_leading_space
    assert_parse('  YES:  All good  ', true, /All good/)
  end

  def test_no_line_then_continuation
    assert_parse("NO:  \n  Some problems", false, /Failed/)
  end

  def test_yes_then_text
    assert_parse('YES: Works correctly YES: Works correctly', true, /Works correctly/)
  end

  private

  def assert_parse(response, expected_verified, desc_pattern = nil)
    verified, desc = @handler.parse_res(response)
    assert_equal expected_verified, verified, "verified mismatch for: #{response.inspect}"
    assert_match desc_pattern, desc, "desc pattern mismatch for: #{response.inspect}" if desc_pattern
  end
end
