# frozen_string_literal: true

module CursorRules
  # REFACTOR.md shipped with the refactor_gpt program directory.
  module ProgramSource
    module_function

    def refactor_md(script_directory)
      Loader.read_file(File.join(script_directory, 'REFACTOR.md')).to_s
    end
  end
end
