# frozen_string_literal: true

module CursorRules
  # User-global `~/.cursor/rules/` (skipped when it is the project rules dir).
  module UserSource
    module_function

    def default_dir
      File.join(Dir.home, Loader::RULES_DIR)
    end

    def parts(project_dir, user_dir: default_dir)
      return [] unless File.directory?(user_dir)

      return [] if File.expand_path(user_dir) == File.expand_path(File.join(project_dir, Loader::RULES_DIR))

      Loader.from_dir(user_dir)
    end
  end
end
