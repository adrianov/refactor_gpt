# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/loader'

class TestToolOutcome < Minitest::Test
  def test_tool_result_error_false_when_not_hash
    refute ToolOutcome.tool_result_error?(nil)
    refute ToolOutcome.tool_result_error?('run_command')
    refute ToolOutcome.tool_result_error?([])
  end

  def test_tool_result_error_false_when_subtype_not_completed
    tool = { subtype: 'invocation', result: { error: 'x' } }
    refute ToolOutcome.tool_result_error?(tool)
    refute ToolOutcome.tool_result_error?({ 'subtype' => 'invocation', 'result' => { 'error' => 'x' } })
  end

  def test_tool_result_error_true_when_completed_with_error_key
    tool = { subtype: 'completed', result: { error: 'failed' } }
    assert ToolOutcome.tool_result_error?(tool)
    assert ToolOutcome.tool_result_error?({ 'subtype' => 'completed', 'result' => { 'error' => 'failed' } })
  end

  def test_tool_result_error_false_when_completed_without_error
    tool = { subtype: 'completed', result: { output: 'ok' } }
    refute ToolOutcome.tool_result_error?(tool)
  end

  def test_tool_result_error_true_when_result_is_json_string_with_error
    tool = { subtype: 'completed', result: '{"error":"something went wrong"}' }
    assert ToolOutcome.tool_result_error?(tool)
  end

  def test_result_has_error_key_nil_false
    refute ToolOutcome.result_has_error_key?(nil)
  end

  def test_result_has_error_key_hash_with_error
    assert ToolOutcome.result_has_error_key?({ error: 'x' })
    assert ToolOutcome.result_has_error_key?({ 'error' => 'x' })
  end

  def test_result_has_error_key_hash_without_error
    refute ToolOutcome.result_has_error_key?({ output: 'ok' })
  end

  def test_result_has_error_key_json_string_with_error
    assert ToolOutcome.result_has_error_key?('{"error": "msg"}')
  end

  def test_result_has_error_key_json_string_without_error
    refute ToolOutcome.result_has_error_key?('{"output": "ok"}')
  end

  def test_invocation_key_nil_for_non_hash
    assert_nil ToolOutcome.invocation_key(nil)
    assert_nil ToolOutcome.invocation_key(1)
  end

  def test_invocation_key_stable_for_name_and_args
    tool = { name: 'run_command', arguments: { path: '/tmp' } }
    key = ToolOutcome.invocation_key(tool)
    assert key.start_with?('run_command')
    assert_includes key, "\0"
    assert_equal key, ToolOutcome.invocation_key('name' => 'run_command', 'arguments' => { 'path' => '/tmp' })
  end

  def test_invocation_key_different_args_different_keys
    a = ToolOutcome.invocation_key({ name: 'run', arguments: { x: 1 } })
    b = ToolOutcome.invocation_key({ name: 'run', arguments: { x: 2 } })
    refute_equal a, b
  end

  def test_invocation_key_same_args_same_key
    args = { path: '/foo' }
    key1 = ToolOutcome.invocation_key({ name: 'run_command', arguments: args })
    key2 = ToolOutcome.invocation_key({ name: 'run_command', arguments: args.dup })
    assert_equal key1, key2
  end

  def test_normalize_args_nil_returns_empty_string
    assert_equal '', ToolOutcome.normalize_args(nil)
  end

  def test_normalize_args_non_hash_array_returns_to_s
    assert_equal 'hello', ToolOutcome.normalize_args('hello')
  end

  def test_normalize_args_skips_explanation_and_tool_call_id
    args = { path: '/x', explanation: 'skip', toolCallId: 'id1' }
    normalized = ToolOutcome.normalize_args(args)
    refute_includes normalized, 'explanation'
    refute_includes normalized, 'toolCallId'
    assert_includes normalized, 'path'
  end

  def test_normalize_args_hash_deterministic_order
    args = { b: 1, a: 2 }
    assert_equal ToolOutcome.normalize_args(args), ToolOutcome.normalize_args(args)
  end
end
