# frozen_string_literal: true

module Quality
  # Static gate for project rule `.cursor/rules/rspec-no-def.mdc`: RSpec files
  # and shared contexts must not define helpers with `def`. Runs in formal so
  # the agent fixes them before review/commit without an LLM guideline pass.
  module RspecDef
    RULE = '.cursor/rules/rspec-no-def.mdc'
    DEF_LINE = /^\s*def\s+(self\.)?([A-Za-z_]\w*[!?=]?)/
    RSPEC_PATH = %r{(?:^|/)spec/.+\.rb$|_spec\.rb$}i

    def rspec_def_report(files)
      lines = Array(files).flat_map { |f| rspec_def_hits(f) }
      return nil if lines.empty?

      "#{RSPEC_DEF_LEFT}\n\n#{truncate(lines.join("\n"))}"
    end

    def rspec_def_hits(path)
      root = git_root(File.dirname(path))
      return [] unless root && File.file?(File.join(root, RULE))
      return [] unless path.match?(RSPEC_PATH) && !third_party?(path)

      rel = rel_to(root, path) || path
      File.readlines(path).each_with_index.filter_map do |line, idx|
        name = line[DEF_LINE, 2]
        next unless name

        "#{rel}:#{idx + 1}: replace `#{name}` - RSpec must not define helpers " \
          'with `def` (use a factory, `let`/`let!`, or inline setup)'
      end
    rescue SystemCallError
      []
    end
  end
end
