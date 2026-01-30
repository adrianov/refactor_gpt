# frozen_string_literal: true

# Shared module for loading project guidelines: AGENTS.md/.cursorrules from project dir, REFACTOR.md from program dir
module AgentsFileHandler
  def load_agents_file(project_root = nil)
    project_dir = project_root || Dir.pwd
    program_dir = script_directory
    parts = %w[AGENTS.md .cursorrules].filter_map do |name|
      path = File.join(project_dir, name)
      next unless File.exist?(path)

      "--- #{name} ---\n#{File.read(path).strip}"
    end
    refactor_path = File.join(program_dir, 'REFACTOR.md')
    parts << "--- REFACTOR.md ---\n#{File.read(refactor_path).strip}" if File.exist?(refactor_path)
    parts.empty? ? '' : parts.join("\n\n")
  end

  def load_refactor_md
    path = File.join(script_directory, 'REFACTOR.md')
    File.exist?(path) ? File.read(path).strip : ''
  end

  def load_env_vars(project_root = nil)
    project_root ||= script_directory
    env_file_path = File.join(project_root, ".env")

    return {} unless File.exist?(env_file_path)

    File.foreach(env_file_path).with_object({}) do |line, h|
      key, value = line.split("=", 2)
      h[key.strip] = value.strip if key && value
    end
  end

  private

  def script_directory
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
