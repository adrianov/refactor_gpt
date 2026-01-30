#!/usr/bin/env ruby
# frozen_string_literal: true

require 'colorize'
require_relative '../lib/superagent/verification_handler'
require_relative '../lib/superagent/display'

# Test verification response parsing
class VerificationParsingTest
  def initialize
    @handler = VerificationHandler.new(Display.new, nil)
    @test_cases = []
    @passed = 0
    @failed = 0
  end

  def test(description, response, expected_verified, expected_desc_pattern = nil)
    @test_cases << {
      description: description,
      response: response,
      expected_verified: expected_verified,
      expected_desc_pattern: expected_desc_pattern
    }
  end

  def run
    puts "Testing verification response parsing...\n\n"

    @test_cases.each_with_index do |test_case, idx|
      verified, desc = @handler.parse_res(test_case[:response])
      
      success = verified == test_case[:expected_verified]
      success &&= desc.match?(test_case[:expected_desc_pattern]) if test_case[:expected_desc_pattern]

      if success
        @passed += 1
        puts "✓ Test #{idx + 1}: #{test_case[:description]}".green
      else
        @failed += 1
        puts "✗ Test #{idx + 1}: #{test_case[:description]}".red
        puts "  Response: #{test_case[:response]}"
        puts "  Expected verified: #{test_case[:expected_verified]}, got: #{verified}"
        puts "  Expected pattern: #{test_case[:expected_desc_pattern]}, got: #{desc}"
      end
    end

    puts "\n#{@passed} passed, #{@failed} failed"
    exit(@failed > 0 ? 1 : 0)
  end
end

test = VerificationParsingTest.new

# Basic YES/NO tests
test.test('Simple YES with description', 'YES: All features implemented correctly', true, /features implemented/)
test.test('Simple NO with description', 'NO: Missing email validation', false, /email validation/)

# Markdown formatting tests
test.test('YES with bold markdown', '**YES**: Feature is complete', true, /Feature is complete/)
test.test('NO with italic markdown', '*NO*: Tests are failing', false, /Tests are failing/)

# Case variations
test.test('Lowercase yes', 'yes: everything works', true, /everything works/)
test.test('Uppercase NO', 'NO: BUGS FOUND', false, /BUGS FOUND/)

# YES/NO without colon
test.test('YES without colon', 'YES All tests pass', true, /tests pass/)
test.test('NO without colon', 'NO Implementation incomplete', false, /Implementation incomplete/)

# Multiple YES/NO (first wins)
test.test('NO before YES', 'NO: Issues found YES: but minor', false, /Issues found/)
test.test('YES before NO', 'YES: Works well NO: with caveats', true, /Works well/)

# Edge cases
test.test('Empty response', '', false)
test.test('No YES or NO', 'The code looks good', false)
test.test('YES at end of sentence', 'I checked and YES: it works', true, /it works/)

# Multiline responses
test.test('Multiline YES', "YES: Implementation is complete\nAll tests passing", true, /Implementation is complete/)
test.test('Multiline NO', "NO: Found several issues\n1. Missing validation\n2. No tests", false, /Found several issues/)

# Whitespace handling
test.test('YES with extra whitespace', '  YES:  All good  ', true, /All good/)
test.test('NO with newlines', "NO:  \n  Some problems", false, /Some problems/)

# Duplicate detection
test.test('Repeated YES', 'YES: Works correctly YES: Works correctly', true, /Works correctly/)

test.run
