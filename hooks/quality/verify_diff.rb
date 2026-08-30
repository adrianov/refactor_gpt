# frozen_string_literal: true

module Quality
  # Histogram diff attachment for the VERIFY follow-up: main modules only
  # (same gate as scatter). Formatted like Cursor's @Uncommitted Changes entity.
  module VerifyDiff
    # Always pass all four; never drop -w, -W, --histogram, or --no-prefix.
    VERIFY_DIFF_OPTS = %w[-w -W --histogram --no-prefix].freeze

    # Same wrapper Cursor uses when the user attaches @Uncommitted Changes.
    GIT_DIFF_INTRO = "Relevant Diff: The following is the git diff of uncommitted " \
                     "changes in the working tree:\n\n"

    def verify_histogram_diff(files)
      Array(files).select { |f| main_module?(f) }.filter_map do |abs|
        root = git_root(File.dirname(abs))
        next unless root && (rel = rel_to(root, abs))

        file_histogram_diff(root, rel)
      end.join("\n")
    end

    def file_histogram_diff(root, rel)
      out, _, code = capture('git', '-C', root, 'diff', *VERIFY_DIFF_OPTS, 'HEAD', '--', rel)
      return out if code.zero? && !out.to_s.empty?
      return nil unless File.file?(File.join(root, rel))

      # Untracked paths are invisible to diff-against-HEAD; show as new-file diff.
      out, _, code = capture(
        'git', '-C', root, 'diff', *VERIFY_DIFF_OPTS, '--no-index', '--', File::NULL, rel
      )
      out if !out.to_s.empty? && [0, 1].include?(code)
    end

    # Mirror Cursor's Hq() serializer: <git_diff> + indented intro + body.
    def git_diff_attach(diff)
      ["<git_diff>", "  #{GIT_DIFF_INTRO}#{utf8_byte_limit(diff, VERIFY_DIFF_LIMIT)}", '  </git_diff>'].join("\n")
    end

    # Cap by bytes without splitting a multibyte UTF-8 character (JSON-safe).
    def utf8_byte_limit(text, limit)
      s = text.to_s
      return s if s.bytesize <= limit

      "#{s.byteslice(0, limit).force_encoding(Encoding::UTF_8).scrub('')}\n... (truncated)"
    end
  end
end
