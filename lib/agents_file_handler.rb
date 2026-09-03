# frozen_string_literal: true

# Facade for project, user, and program guidelines, plus `.env` loading.
module AgentsFileHandler
  RULES_LABEL = 'Project and user Cursor rules'

  def load_agents_file(project_root = nil)
    project_dir = project_root || Dir.pwd
    CursorRules::Loader.join_parts(rule_parts(project_dir) + [load_refactor_md])
  end

  def load_project_rules(project_root = nil)
    CursorRules::Loader.join_parts(rule_parts(project_root || Dir.pwd))
  end

  def formatted_project_rules(project_root = nil)
    rules = load_project_rules(project_root)
    rules.empty? ? '' : "#{RULES_LABEL}:\n#{rules}"
  end

  def load_refactor_md
    CursorRules::ProgramSource.refactor_md(script_directory)
  end

  def load_env_vars(project_root = nil)
    project_root ||= script_directory
    env_file_path = File.join(project_root, '.env')
    return {} unless File.exist?(env_file_path)

    File.binread(env_file_path).force_encoding(Encoding::UTF_8).scrub('').each_line.with_object({}) do |line, h|
      key, value = line.split('=', 2)
      h[key.strip] = value.strip if key && value
    end
  end

  private

  def rule_parts(project_dir)
    CursorRules::ProjectSource.parts(project_dir) +
      CursorRules::UserSource.parts(project_dir, user_dir: user_cursor_rules_dir)
  end

  def user_cursor_rules_dir
    @user_cursor_rules_dir || CursorRules::UserSource.default_dir
  end

  def script_directory
    return REFACTOR_GPT_ROOT if defined?(REFACTOR_GPT_ROOT) && !REFACTOR_GPT_ROOT.to_s.empty?
    return resolve_script_dir if $PROGRAM_NAME && !$PROGRAM_NAME.empty?

    Dir.pwd
  end

  def resolve_script_dir
    script_path = $PROGRAM_NAME
    script_dir = File.dirname(File.expand_path(script_path))
    return script_dir if File.directory?(script_dir)

    which_path = `which #{script_path} 2>/dev/null`.strip
    return File.dirname(which_path) if !which_path.empty? && File.exist?(which_path)

    script_dir
  end
end
