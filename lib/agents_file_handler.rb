# frozen_string_literal: true

# Shared module for handling AGENTS.md file operations
module AgentsFileHandler
  def load_agents_file
    # Only try current working directory
    agents_file = File.join(Dir.pwd, 'AGENTS.md')

    return '' unless File.exist?(agents_file)

    File.read(agents_file)
  end
end
