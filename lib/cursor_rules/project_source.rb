# frozen_string_literal: true

module CursorRules
  # AGENTS.md, .cursorrules, and the project's `.cursor/rules/` directory.
  module ProjectSource
    ROOT_FILES = %w[AGENTS.md .cursorrules].freeze

    module_function

    def parts(project_dir)
      ROOT_FILES.filter_map { |name| Loader.read_file(File.join(project_dir, name)) } +
        Loader.from_dir(File.join(project_dir, Loader::RULES_DIR))
    end
  end
end
