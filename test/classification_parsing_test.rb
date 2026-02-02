# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require 'oj'
require_relative '../lib/loader'

# Tests for session classification: continuation/description parsing and prompt title.
class TestClassificationParsing < Minitest::Test
  def setup
    @config_dir = Dir.mktmpdir
    @orig_config_dir = ConfigPath::CONFIG_DIR
    @orig_session_dir = SessionTracker::SESSION_DIR
    ConfigPath.send(:remove_const, :CONFIG_DIR)
    ConfigPath.const_set(:CONFIG_DIR, @config_dir)
    SessionTracker.send(:remove_const, :SESSION_DIR)
    SessionTracker.const_set(:SESSION_DIR, @config_dir)
    @tracker = SessionTracker.new(Display.new)
  end

  def teardown
    ConfigPath.send(:remove_const, :CONFIG_DIR)
    ConfigPath.const_set(:CONFIG_DIR, @orig_config_dir)
    SessionTracker.send(:remove_const, :SESSION_DIR)
    SessionTracker.const_set(:SESSION_DIR, @orig_session_dir)
    FileUtils.rm_rf(@config_dir) if @config_dir && Dir.exist?(@config_dir)
  end

  def write_sessions(sessions)
    path = File.join(@config_dir, "#{ConfigPath.project_id}.json")
    FileUtils.mkdir_p(@config_dir)
    payload = { sessions: sessions }
    File.write(path, Oj.dump(payload, mode: :compat, indent: 2))
  end

  def valid_session(description:, request: description)
    {
      request: request.to_s[0..200],
      timestamp: Time.now.to_i,
      description: description.to_s[0..200]
    }
  end

  def test_continuation_prompt_title_empty_sessions
    _prompt, title = @tracker.continuation_prompt_and_title('add login', [])
    assert_equal 'Classifying request', title
  end

  def test_continuation_prompt_title_with_sessions
    sessions = [valid_session(description: 'add login')]
    _prompt, title = @tracker.continuation_prompt_and_title('fix login bug', sessions)
    assert_equal 'Classifying to a session', title
  end

  def test_parse_response_nil_returns_default
    out = @tracker.send(:parse_continuation_and_description_response, nil, [], 'add feature')
    assert_equal false, out[:continuation]
    assert_equal [], out[:tags]
    assert_nil out[:description]
    assert_nil out[:continuation_id]
  end

  def test_parse_response_empty_sessions_uses_description_from_response
    response = <<~TEXT
      TAGS: #feature
      DESCRIPTION: add user login with email
    TEXT
    out = @tracker.send(:parse_continuation_and_description_response, response, [], 'add login')
    assert_equal false, out[:continuation]
    assert_equal %w[#feature], out[:tags]
    assert_equal 'add user login with email', out[:description]
    assert_nil out[:continuation_id]
  end

  def test_parse_response_continuation_new_no_number
    write_sessions([valid_session(description: 'add login')])
    @tracker.load_sessions
    response = <<~TEXT
      CONTINUATION: NEW
      TAGS: #feature
      DESCRIPTION: add user dashboard
    TEXT
    sessions = @tracker.active_sessions_newest_first
    out = @tracker.send(:parse_continuation_and_description_response, response, sessions, 'add dashboard')
    assert_equal false, out[:continuation]
    assert_equal %w[#feature], out[:tags]
    assert_equal 'add user dashboard', out[:description]
    assert_nil out[:continuation_id]
  end

  def test_parse_response_continuation_number_matches_session
    write_sessions([
                    valid_session(description: 'add dashboard'),
                    valid_session(description: 'add login with email')
                  ])
    @tracker.load_sessions
    sessions = @tracker.active_sessions_newest_first
    # Session 1 = newest (last in file) = "add login with email", session 2 = "add dashboard"
    response = <<~TEXT
      CONTINUATION: 1
      TAGS: #bug
      DESCRIPTION: fix login validation
    TEXT
    out = @tracker.send(:parse_continuation_and_description_response, response, sessions, 'fix validation')
    assert_equal true, out[:continuation]
    assert_equal 1, out[:continuation_id]
    assert_equal %w[#bug], out[:tags]
    assert_equal 'add login with email', out[:description]
  end

  def test_parse_response_tags_none
    response = "TAGS: NONE\nDESCRIPTION: some task"
    out = @tracker.send(:parse_continuation_and_description_response, response, [], 'task')
    assert_equal [], out[:tags]
    assert_equal 'some task', out[:description]
  end

  def test_parse_response_tags_multiple
    response = "TAGS: #refactoring, #improvement\nDESCRIPTION: clean up service"
    out = @tracker.send(:parse_continuation_and_description_response, response, [], 'cleanup')
    assert_equal %w[#refactoring #improvement], out[:tags]
    assert_equal 'clean up service', out[:description]
  end

  def test_parse_response_description_fallback_when_missing
    response = "TAGS: #feature"
    out = @tracker.send(:parse_continuation_and_description_response, response, [], 'add new button')
    assert out[:description].to_s.start_with?('Session: ')
    assert_includes out[:description], 'add new button'
  end

  def test_parse_response_continuation_invalid_number_uses_description_from_response
    write_sessions([valid_session(description: 'add login')])
    @tracker.load_sessions
    sessions = @tracker.active_sessions_newest_first
    response = <<~TEXT
      CONTINUATION: 99
      TAGS: #bug
      DESCRIPTION: fix the login bug
    TEXT
    out = @tracker.send(:parse_continuation_and_description_response, response, sessions, 'fix bug')
    assert_equal false, out[:continuation]
    assert_nil out[:continuation_id]
    assert_equal 'fix the login bug', out[:description]
  end
end
