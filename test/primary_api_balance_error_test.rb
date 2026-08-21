# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/loader'

# Balance/1113 detection and hard-exit handling (no provider fallback).
class TestPrimaryApiBalanceError < Minitest::Test
  BALANCE_MSG = 'Insufficient balance or no resource package. Please recharge.'
  BALANCE_BODY = '{"error":{"code":"1113","message":"Insufficient balance or no resource package. Please recharge."}}'

  def test_balance_exhausted_detects_message_and_code
    client = OpenrouterClient.allocate
    assert client.send(:balance_exhausted?, BALANCE_MSG, nil)
    assert client.send(:balance_exhausted?, nil, BALANCE_BODY)
    refute client.send(:balance_exhausted?, 'Rate limit exceeded', '{"error":{"code":"429"}}')
  end

  def test_balance_error_exits_without_retry
    client = OpenrouterClient.allocate
    out, err = capture_io do
      assert_raises(SystemExit) do
        client.send(:exit_balance_error, 429, "Primary API balance exhausted: #{BALANCE_MSG}", BALANCE_BODY)
      end
    end
    assert_includes out + err, 'Insufficient balance'
  end
end
