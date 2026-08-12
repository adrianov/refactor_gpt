# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require_relative '../lib/loader'

# System prompts must stay byte-stable for the same project rules while git/cwd
# changes ride on the user turn (prompt-cache friendly).
class TestSystemPromptStability < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir('system_prompt_stability')
    File.write(File.join(@tmpdir, 'AGENTS.md'), "Always use snake_case.\n")
    File.write(File.join(@tmpdir, '.cursorrules'), "Prefer small methods.\n")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def test_ask_system_stable_across_dated_user_turns
    client = Class.new { include AskClientInstructions }.new
    system_text = client.build_system_instruction(nil, nil)
    assert_equal system_text, client.build_system_instruction(nil, nil)
    refute_system_has_runtime_state(system_text)

    prepared = client.prepare_ask_messages(
      [client.build_system_message(nil, nil), {role: 'user', content: 'Explain Enumerable'}]
    )
    assert_equal system_text, prepared.first[:content]
    assert_includes prepared.last[:content], 'Current date/time:'
  end

  def test_commit_plan_system_stable_for_same_rules_different_changes
    client = CommitPlanClient.new(debug: false, progress: false)
    with_project_dir do
      system_text = client.send(:system_instruction)
      assert_equal system_text, client.send(:system_instruction)
      assert_project_rules_in_system(system_text)
      refute_includes system_text, 'lib/a.rb'
      refute_includes system_text, '+one'
      assert_commit_users_differ(client)
    end
  end

  def test_conflict_resolve_system_stable_for_same_rules
    rules = File.read(File.join(@tmpdir, 'AGENTS.md')) + File.read(File.join(@tmpdir, '.cursorrules'))
    system_text = ConflictResolvePrompt.system_instruction(rules)
    assert_equal system_text, ConflictResolvePrompt.system_instruction(rules)
    assert_includes system_text, 'Always use snake_case.'
    refute_includes system_text, '<<<<<<< HEAD'
    refute_includes system_text, 'lib/x.rb'
    assert_conflict_user_has_markers
  end

  def test_bash_analyze_system_omits_host_state
    a = BashPrompt.analyze_messages('list files', host_context: bash_host('/tmp/a', "a.rb\n"))
    b = BashPrompt.analyze_messages('show status', host_context: bash_host('/tmp/b', "b.rb\n"))
    assert_stable_system(a, b, BashPrompt.analyze_system_instruction)
    refute_includes a[0][:content], '/tmp/a'
    assert_includes a[1][:content], '/tmp/a'
  end

  def test_bash_command_system_omits_command_context
    host = bash_host('/tmp/a', "a.rb\n")
    a = BashPrompt.command_messages('list', host_context: host, context_output: 'git status\n M a.rb')
    b = BashPrompt.command_messages('diff', host_context: host, context_output: 'git diff\n+line')
    assert_stable_system(a, b, BashPrompt.command_system_instruction)
    refute_includes a[0][:content], 'git status'
    assert_includes a[1][:content], ' M a.rb'
  end

  def test_ag_system_stable_across_different_project_keywords
    a = AgPrompt.search_messages('find User', project_keywords: 'user service')
    b = AgPrompt.search_messages('find Order', project_keywords: 'order payment')
    assert_stable_system(a, b, AgPrompt.search_system_instruction)
    refute_includes a[0][:content], 'user service'
    assert_includes a[1][:content], 'user service'
  end

  def test_agent_guidelines_stable_and_separate_from_git_state
    builder = agent_builder_with_modified(%w[lib/changed.rb])
    with_project_dir do
      guidelines = builder.guidelines_section(always_include: true)
      assert_equal guidelines, builder.guidelines_section(always_include: true)
      assert_project_rules_in_system(guidelines)
      refute_system_has_runtime_state(guidelines)
      refute_includes guidelines, 'lib/changed.rb'
      assert_includes builder.modified_files_section, 'lib/changed.rb'
    end
  end

  private

  def assert_stable_system(messages_a, messages_b, expected_system)
    assert_equal expected_system, messages_a[0][:content]
    assert_equal messages_a[0][:content], messages_b[0][:content]
    refute_equal messages_a[1][:content], messages_b[1][:content]
  end

  def with_project_dir
    original = Dir.pwd
    Dir.chdir(@tmpdir)
    yield
  ensure
    Dir.chdir(original)
  end

  def assert_project_rules_in_system(text)
    assert_includes text, 'Always use snake_case.'
    assert_includes text, 'Prefer small methods.'
  end

  def refute_system_has_runtime_state(text)
    refute_includes text, 'Current date/time'
    refute_includes text, 'Current time'
    refute_includes text, 'Git status'
    refute_includes text, 'Git diff'
    refute_includes text, 'git status'
  end

  def assert_commit_users_differ(client)
    user_a = commit_user(client, " M lib/a.rb\n", "diff --git a/lib/a.rb\n+one\n", 'abc1 first', 'ls')
    user_b = commit_user(client, " M lib/b.rb\n", "diff --git a/lib/b.rb\n+two\n", 'def2 second', 'pwd')
    refute_equal user_a, user_b
    assert_includes user_a, 'lib/a.rb'
    assert_includes user_b, 'lib/b.rb'
  end

  def assert_conflict_user_has_markers
    user = ConflictResolvePrompt.user_prompt(
      'lib/x.rb', "<<<<<<< HEAD\na\n=======\nb\n>>>>>>> branch\n", {}, 'commit intent'
    )
    assert_includes user, '<<<<<<< HEAD'
    assert_includes user, 'commit intent'
  end

  def commit_user(client, status, diff, commits, commands)
    client.send(:build_user_content, status, '', diff, '', commits, commands)
  end

  def bash_host(pwd, listing)
    BashPrompt.host_context(pwd: pwd, listing: listing, system_info: 'OS: macOS')
  end

  def agent_builder_with_modified(files)
    tracker = Object.new
    tracker.define_singleton_method(:get_modified_files) { files }
    AgentPromptBuilder.new(tracker)
  end
end
