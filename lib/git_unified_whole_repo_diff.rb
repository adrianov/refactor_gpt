# frozen_string_literal: true

require 'open3'

# Whole-repository unified diff fallback variants (full → lighter unified → same with --no-ext-diff).
# Shared by git_commit_gpt try_git_unified_against and GitCommitDiffCompaction whole-repo fallback.
class GitUnifiedWholeRepoDiff
  # Ignore-all-space, function-context (-W), histogram algorithm; richest unified diff.
  FULL_OPTS = %w[-w -W --no-prefix --histogram].freeze
  # Lighter unified: ignore-all-space only — drops -W (word/function-context hunks) and explicit histogram.
  LIGHT_UNIFIED_OPTS = %w[-w --no-prefix].freeze

  class << self
    def capture(ref_suffix)
      capture_with_stderr(ref_suffix).first
    end

    def capture_with_stderr(ref_suffix)
      last_err = +''
      variant_arg_lists(ref_suffix).each do |args|
        out, err, st = Open3.capture3('git', 'diff', *args)
        last_err = err.to_s
        return [out, err] if st.success?
      end
      [nil, last_err]
    end

    def variant_arg_lists(ref_suffix)
      suff = ref_suffix ? [ref_suffix] : []
      [
        FULL_OPTS + suff,
        LIGHT_UNIFIED_OPTS + suff,
        ['--no-ext-diff'] + FULL_OPTS + suff,
        ['--no-ext-diff'] + LIGHT_UNIFIED_OPTS + suff
      ]
    end
  end
end
