# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/loader'

class TestSameToolErrorTracker < Minitest::Test
  def test_three_errors_same_key_returns_interrupt_on_third
    tracker = SameToolErrorTracker.new
    assert_equal :ok, tracker.record('run_command', error: true)
    assert_equal :ok, tracker.record('run_command', error: true)
    assert_equal :interrupt, tracker.record('run_command', error: true)
  end

  def test_success_resets_count_for_key
    tracker = SameToolErrorTracker.new
    tracker.record('run_command', error: true)
    tracker.record('run_command', error: true)
    tracker.record('run_command', error: false)
    assert_equal :ok, tracker.record('run_command', error: true)
    assert_equal :ok, tracker.record('run_command', error: true)
    assert_equal :interrupt, tracker.record('run_command', error: true)
  end

  def test_different_keys_tracked_independently
    tracker = SameToolErrorTracker.new
    tracker.record('key_a', error: true)
    tracker.record('key_a', error: true)
    assert_equal :ok, tracker.record('key_b', error: true)
    assert_equal :interrupt, tracker.record('key_a', error: true)
    assert_equal :ok, tracker.record('key_b', error: true)
    assert_equal :interrupt, tracker.record('key_b', error: true)
  end

  def test_reset_clears_counts
    tracker = SameToolErrorTracker.new
    tracker.record('run_command', error: true)
    tracker.record('run_command', error: true)
    tracker.reset
    assert_equal :ok, tracker.record('run_command', error: true)
    assert_equal :ok, tracker.record('run_command', error: true)
    assert_equal :interrupt, tracker.record('run_command', error: true)
  end

  def test_nil_key_returns_ok
    tracker = SameToolErrorTracker.new
    assert_equal :ok, tracker.record(nil, error: true)
    assert_equal :ok, tracker.record(nil, error: true)
  end

  def test_custom_threshold
    tracker = SameToolErrorTracker.new(threshold: 2)
    assert_equal :ok, tracker.record('key', error: true)
    assert_equal :interrupt, tracker.record('key', error: true)
  end

  # Ensures parser output (tool_call NDJSON → tool hash) still feeds the safeguard: same tool+args
  # failing 3 times in a row triggers :interrupt.
  def test_interrupt_after_three_same_tool_errors_with_parser_tool_shape
    line = '{"type":"tool_call","subtype":"completed","tool_call":' \
           '{"runCommandToolCall":{"args":{"path":"/tmp"},"result":{"error":"failed"}}}}'
    parsed = StreamLineParser.new.parse_stream_line(line)
    tool = parsed[:tool]
    assert tool, 'parser must produce tool for tool_call line'
    key = ToolOutcome.invocation_key(tool)
    assert key, 'invocation key must be built from parser tool'
    assert ToolOutcome.tool_result_error?(tool), 'parser tool with result.error must be treated as error'
    tracker = SameToolErrorTracker.new
    assert_equal :ok, tracker.record(key, error: true)
    assert_equal :ok, tracker.record(key, error: true)
    assert_equal :interrupt, tracker.record(key, error: true)
  end
end
