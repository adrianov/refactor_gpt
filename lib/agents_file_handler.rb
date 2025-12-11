# frozen_string_literal: true

# Shared module for handling AGENTS.md file operations
module AgentsFileHandler
  def load_agents_file
    # First try project root (one level up from lib/)
    agents_file = File.join(File.dirname(__dir__), 'AGENTS.md')

    # Fallback to current directory if not found
    unless File.exist?(agents_file)
      agents_file = File.join(Dir.pwd,
                              'AGENTS.md')
    end

    return '' unless File.exist?(agents_file)

    File.read(agents_file)
  rescue SystemCallError
    ''
  end
end
