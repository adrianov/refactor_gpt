# frozen_string_literal: true

# Shared module for handling AGENTS.md file operations
module AgentsFileHandler
  def load_agents_file(project_root = nil)
    project_root ||= script_directory
    agents_file = File.join(project_root, 'AGENTS.md')

    return '' unless File.exist?(agents_file)

    File.read(agents_file)
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
