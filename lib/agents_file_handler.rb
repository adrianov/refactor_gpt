# frozen_string_literal: true

# Shared module for handling AGENTS.md file operations
module AgentsFileHandler
  def load_agents_file(project_root = Dir.pwd)
    agents_file = File.join(project_root, 'AGENTS.md')

    return '' unless File.exist?(agents_file)

    File.read(agents_file)
  end

  def load_env_vars(project_root = Dir.pwd)
    env_file_path = File.join(project_root, ".env")

    return {} unless File.exist?(env_file_path)

    File.foreach(env_file_path).with_object({}) do |line, h|
      key, value = line.split("=", 2)
      h[key.strip] = value.strip if key && value
    end
  end
end
