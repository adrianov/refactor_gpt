# frozen_string_literal: true

# Shared module for loading project guidelines from AGENTS.md, .cursorrules,
# .cursor/rules/*.{mdc,md}, and REFACTOR.md from the program directory.
module AgentsFileHandler
  PROJECT_ROOT_RULE_FILES = %w[AGENTS.md .cursorrules].freeze
  CURSOR_RULES_DIR = '.cursor/rules'
  CURSOR_RULE_EXTENSIONS = %w[mdc md].freeze

  def load_agents_file(project_root = nil)
    project_dir = project_root || Dir.pwd
    parts = collect_project_rule_parts(project_dir)
    append_program_refactor_md(parts)
    join_rule_parts(parts)
  end

  def load_project_rules(project_root = nil)
    join_rule_parts(collect_project_rule_parts(project_root || Dir.pwd))
  end

  def load_refactor_md
    path = File.join(script_directory, 'REFACTOR.md')
    File.exist?(path) ? read_utf8_file(path).strip : ''
  end

  def load_env_vars(project_root = nil)
    project_root ||= script_directory
    env_file_path = File.join(project_root, '.env')
    return {} unless File.exist?(env_file_path)

    read_utf8_file(env_file_path).each_line.with_object({}) do |line, h|
      key, value = line.split('=', 2)
      h[key.strip] = value.strip if key && value
    end
  end

  private

  def collect_project_rule_parts(project_dir)
    read_root_rule_files(project_dir) + read_cursor_rule_file_bodies(project_dir)
  end

  def read_root_rule_files(project_dir)
    PROJECT_ROOT_RULE_FILES.filter_map do |name|
      read_rule_file(File.join(project_dir, name))
    end
  end

  def read_cursor_rule_file_bodies(project_dir)
    rules_dir = File.join(project_dir, CURSOR_RULES_DIR)
    return [] unless File.directory?(rules_dir)

    cursor_rule_paths(rules_dir).filter_map { |path| read_cursor_rule_file(path) }
  end

  def cursor_rule_paths(rules_dir)
    CURSOR_RULE_EXTENSIONS.flat_map do |ext|
      Dir.glob(File.join(rules_dir, '**', "*.#{ext}"))
    end.uniq.sort
  end

  def read_cursor_rule_file(path)
    body = read_rule_file(path)
    return nil if body.nil?

    File.extname(path) == '.mdc' ? strip_mdc_frontmatter(body) : body
  end

  def read_rule_file(path)
    return nil unless File.file?(path)

    body = read_utf8_file(path).strip
    body.empty? ? nil : body
  end

  # Binary read + scrub avoids US-ASCII locale crashes on non-ASCII file bytes.
  def read_utf8_file(path)
    File.binread(path).force_encoding(Encoding::UTF_8).scrub('')
  end

  def strip_mdc_frontmatter(text)
    return text unless text.start_with?('---')

    stripped = text.sub(/\A---\s*\n.*?\n---\s*\n/m, '')
    stripped.strip.empty? ? text : stripped.strip
  end

  def append_program_refactor_md(parts)
    refactor_path = File.join(script_directory, 'REFACTOR.md')
    parts << read_utf8_file(refactor_path).strip if File.exist?(refactor_path)
  end

  def join_rule_parts(parts)
    cleaned = parts.map(&:strip).reject(&:empty?)
    cleaned.empty? ? '' : cleaned.join("\n\n")
  end

  def script_directory
    return REFACTOR_GPT_ROOT if defined?(REFACTOR_GPT_ROOT) && !REFACTOR_GPT_ROOT.to_s.empty?
    return resolve_script_dir if $PROGRAM_NAME && !$PROGRAM_NAME.empty?

    Dir.pwd
  end

  def resolve_script_dir
    script_path = $PROGRAM_NAME

    # Always expand to absolute path - this works even when running from different directories
    # File.expand_path resolves relative paths relative to current working directory
    expanded_path = File.expand_path(script_path)

    # Get the directory of the script
    script_dir = File.dirname(expanded_path)

    # Verify the directory exists (more reliable than checking if file exists)
    return script_dir if File.directory?(script_dir)

    # If directory doesn't exist, the path might be a command name from PATH
    # Try to find it using 'which'
    which_path = `which #{script_path} 2>/dev/null`.strip
    return File.dirname(which_path) if !which_path.empty? && File.exist?(which_path)

    # Final fallback: use the expanded path directory anyway
    script_dir
  end
end
