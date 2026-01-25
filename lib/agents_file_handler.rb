# frozen_string_literal: true

# Shared module for handling AGENTS.md file operations
module AgentsFileHandler
  def load_agents_file
    # Only try current working directory
    agents_file = File.join(Dir.pwd, 'AGENTS.md')

    return '' unless File.exist?(agents_file)

    File.read(agents_file)
  end

  def load_env_vars
    # First try project root (one level up from lib/)
    env_file_path = File.join(File.dirname(__dir__), ".env")

    # Fallback to current directory if not found
    env_file_path = File.join(Dir.pwd, ".env") unless File.exist?(env_file_path)

    return {} unless File.exist?(env_file_path)

    File.foreach(env_file_path).with_object({}) do |line, h|
      key, value = line.split("=", 2)
      h[key.strip] = value.strip if key && value
    end
  end
end
