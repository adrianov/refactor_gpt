# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require_relative '../lib/loader'

class AgentsFileHandlerTestHost
  include AgentsFileHandler
end

class AgentsFileHandlerTest < Minitest::Test
  def setup
    @host = AgentsFileHandlerTestHost.new
    @tmpdir = Dir.mktmpdir('agents_file_handler_test')
    @user_rules_dir = File.join(@tmpdir, 'home', '.cursor', 'rules')
    @host.instance_variable_set(:@user_cursor_rules_dir, @user_rules_dir)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def test_load_project_rules_includes_root_and_cursor_rule_files
    write_file('AGENTS.md', 'agents content')
    write_file('.cursorrules', 'cursorrules content')
    write_cursor_rule('ruby-style.mdc', "---\ndescription: style\n---\n\nRuby style rules")
    write_cursor_rule('notes.md', 'Extra markdown rule')
    write_user_cursor_rule('global.mdc', "---\nalwaysApply: true\n---\n\nUser home cursor rule")

    rules = @host.load_project_rules(@tmpdir)

    assert_includes rules, 'agents content'
    assert_includes rules, 'cursorrules content'
    assert_includes rules, 'Ruby style rules'
    refute_includes rules, 'description: style'
    assert_includes rules, 'Extra markdown rule'
    assert_includes rules, 'User home cursor rule'
    assert_includes @host.formatted_project_rules(@tmpdir), AgentsFileHandler::RULES_LABEL
  end

  def test_load_project_rules_skips_missing_user_cursor_rules_dir
    write_file('AGENTS.md', 'agents only')

    rules = @host.load_project_rules(@tmpdir)

    assert_equal 'agents only', rules
  end

  def test_load_project_rules_skips_user_dir_when_same_as_project
    write_file('AGENTS.md', 'agents only')
    write_cursor_rule('local.md', 'project cursor rule')
    project_rules_dir = File.join(@tmpdir, '.cursor', 'rules')
    @host.instance_variable_set(:@user_cursor_rules_dir, project_rules_dir)

    rules = @host.load_project_rules(@tmpdir)

    assert_equal "agents only\n\nproject cursor rule", rules
  end

  def test_script_directory_stays_on_tool_root_after_chdir
    original = Dir.pwd
    Dir.chdir(@tmpdir)
    assert_equal REFACTOR_GPT_ROOT, @host.send(:script_directory)
  ensure
    Dir.chdir(original)
  end

  def test_load_agents_file_appends_program_refactor_md
    write_file('AGENTS.md', 'agents only')
    refactor_path = File.join(@tmpdir, 'REFACTOR.md')
    File.write(refactor_path, 'refactor defaults')

    refactor_dir = File.dirname(refactor_path)
    missing_user_dir = File.join(@tmpdir, 'missing-user-rules')
    host = Class.new do
      include AgentsFileHandler

      define_method(:script_directory) { refactor_dir }
      define_method(:user_cursor_rules_dir) { missing_user_dir }
    end.new

    combined = host.load_agents_file(@tmpdir)

    assert_includes combined, 'agents only'
    assert_includes combined, 'refactor defaults'
  end

  def test_load_env_vars_tolerates_non_ascii_under_us_ascii_locale
    File.binwrite(
      File.join(@tmpdir, '.env'),
      "FOO=bar\n# comment \xD0\xBF\xD1\x80\nBAZ=1\nBAD=caf\xE9\n"
    )

    with_us_ascii_locale do
      env = @host.load_env_vars(@tmpdir)
      assert_equal 'bar', env['FOO']
      assert_equal '1', env['BAZ']
      assert_equal 'caf', env['BAD']
    end
  end

  def test_load_project_rules_tolerates_non_ascii_under_us_ascii_locale
    File.binwrite(File.join(@tmpdir, 'AGENTS.md'), "agents \xD0\xBF\xD1\x80\n")
    File.binwrite(File.join(@tmpdir, '.cursorrules'), "rules caf\xE9\n")

    with_us_ascii_locale do
      rules = @host.load_project_rules(@tmpdir)
      assert_includes rules, 'agents'
      assert_includes rules, 'rules caf'
    end
  end

  private

  def with_us_ascii_locale
    old_external = Encoding.default_external
    old_internal = Encoding.default_internal
    Encoding.default_external = Encoding::US_ASCII
    Encoding.default_internal = nil
    yield
  ensure
    Encoding.default_external = old_external
    Encoding.default_internal = old_internal
  end

  def write_file(name, content)
    File.write(File.join(@tmpdir, name), content)
  end

  def write_cursor_rule(name, content)
    write_rule_file(File.join(@tmpdir, '.cursor', 'rules'), name, content)
  end

  def write_user_cursor_rule(name, content)
    write_rule_file(@user_rules_dir, name, content)
  end

  def write_rule_file(dir, name, content)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, name), content)
  end
end
