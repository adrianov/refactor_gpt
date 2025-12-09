# frozen_string_literal: true

# Shared module for handling AGENTS.md file operations
module AgentsFileHandler
  def load_agents_file
    agents_file = File.join(File.dirname(__FILE__), 'AGENTS.md')
    return '' unless File.exist?(agents_file)

    File.read(agents_file)
  rescue SystemCallError
    ''
  end
end
