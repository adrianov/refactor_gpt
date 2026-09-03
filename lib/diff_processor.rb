# frozen_string_literal: true


# Builds and filters unified diffs for commit planning.
class DiffProcessor
  include DiffProcessorBudget
  include DiffProcessorFiles

  FILE_TRUNCATION_SUFFIX = "\n... (file truncated due to size limit)\n"
  FILE_DIFF_SEPARATOR = "\n\n"
  MAX_LINE_BEFORE_MID_CUT = 2000

  CODE_EXTENSIONS = %w[
    .rb .c .h .cpp .hpp .cc .cxx .java .py .js .ts .jsx .tsx .go .rs .swift
    .kt .scala .cs .php .pl .pm .sh .bash .zsh .lua .r .m .mm .sql .graphql
    .vue .svelte .css .scss .sass .less .html .htm .xml .json .yaml .yml
    .toml .ini .conf .md .markdown .txt .rake .gemspec
  ].freeze

  def initialize(compactor: nil)
    @compactor = compactor || DiffCompactor.new
  end

  def build_sorted_diff(diff_output, status_output, max_bytes)
    return "" if diff_output.empty?

    file_diffs = parse_file_diffs(diff_output)
    return diff_output if file_diffs.empty?

    file_statuses = parse_file_statuses(status_output)
    included_diffs, skipped_count = collect_diffs(
      sort_files_by_importance(file_diffs, file_statuses), file_statuses, max_bytes
    )
    assemble_result(included_diffs, skipped_count)
  end

  # Returns diff with file sections for given paths removed. Used to drop
  # build logs and other non-source files before sending diff to the LLM.
  def diff_without_paths(diff_output, excluded_paths)
    return diff_output if diff_output.empty? || excluded_paths.empty?

    file_diffs = parse_file_diffs(diff_output)
    return diff_output if file_diffs.empty?

    set = excluded_paths.to_set
    file_diffs.reject { |path, _| set.include?(path) }.values.join(FILE_DIFF_SEPARATOR)
  end

  private

  def assemble_result(included_diffs, skipped_count)
    result = included_diffs.join(FILE_DIFF_SEPARATOR)
    result += "\n\n... (#{skipped_count} more file(s) skipped or truncated due to size limit)\n" if skipped_count > 0
    result
  end
end
