# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/loader'

class TestRequestPreparer < Minitest::Test
  def models
    Superagent::MODELS
  end

  def test_extract_model_index_exact_tag
    assert_equal 0, RequestPreparer.extract_model_index('@auto fix bug', models)
    assert_equal 1, RequestPreparer.extract_model_index('use @grok', models)
  end

  def test_extract_model_index_word_boundary_tag
    assert_equal 4, RequestPreparer.extract_model_index('@sonnet refactor', models)
    assert_equal 5, RequestPreparer.extract_model_index('@opus please', models)
    assert_equal 3, RequestPreparer.extract_model_index('@composer help', models)
    assert_equal 2, RequestPreparer.extract_model_index('@gemini task', models)
  end

  def test_extract_model_index_standalone_word_ignored
    assert_nil RequestPreparer.extract_model_index('sonnet fix bug', models)
    assert_nil RequestPreparer.extract_model_index('use opus', models)
  end

  def test_extract_model_index_unknown_tag_returns_nil
    assert_nil RequestPreparer.extract_model_index('@unknown task', models)
  end

  def test_extract_model_index_unknown_standalone_returns_nil
    assert_nil RequestPreparer.extract_model_index('unknown task', models)
  end

  def test_sanitize_request_strips_model_mentions
    assert_equal 'fix bug', RequestPreparer.sanitize_request('@sonnet fix bug', models)
    assert_equal 'refactor', RequestPreparer.sanitize_request('refactor @opus', models)
  end

  def test_sanitize_request_keeps_standalone_model_words
    assert_equal 'sonnet fix bug', RequestPreparer.sanitize_request('sonnet fix bug', models)
    assert_equal 'refactor opus', RequestPreparer.sanitize_request('refactor opus', models)
  end

  def test_sanitize_request_keeps_unknown_mentions
    assert_equal 'ask @unknown', RequestPreparer.sanitize_request('ask @unknown', models)
  end

  def test_sanitize_request_keeps_unknown_standalone_words
    assert_equal 'ask unknown', RequestPreparer.sanitize_request('ask unknown', models)
  end
end
