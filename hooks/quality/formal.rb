# frozen_string_literal: true

require 'fileutils'

module Quality
  # Formal stage machinery: the per-cycle abcop lint over every supported
  # language. Scoping is fully delegated: a plain `abcop` run with no PATHS
  # scans the current-MR scope itself (changes since branching from
  # master/main plus uncommitted work), including ModuleSize and oversized
  # specs — no home-grown size reports here.
  module Formal
    def formal_stage(files, saved, chain)
      targets = formal_targets(files, saved, chain)
      msg = formal_report(targets)
      return nil unless msg

      unset_review_flags
      save_stage('formal', targets)
      followup(msg)
    end
    def formal_targets(files, saved, chain)
      t = files.empty? ? saved.dup : files.dup
      t = (t + saved).uniq if chain && !files.empty?
      t.select { |f| File.file?(f) }
    end

    def formal_report(files)
      return nil if files.nil? || files.empty?

      parts = [abcop_report(files)].compact
      parts.empty? ? nil : parts.join("\n\n")
    end

    # One plain run per repository: with no path arguments abcop applies its
    # own MR heuristics over every supported file type, so only the repo root
    # matters here. Result cache stays enabled — repeat scans over unchanged
    # files are cheap.
    def abcop_report(files)
      bin = which('abcop')
      unless bin
        STDERR.puts '[quality] abcop not found on PATH; skip'
        return nil
      end

      rem = abcop_by_root(bin, files)
      rem.strip.empty? ? nil : "#{ABCOP_LEFT}\n\n#{truncate(rem)}"
    end

    def abcop_by_root(bin, files)
      roots = files.filter_map { |f| git_root(File.dirname(f)) }.uniq
      roots.filter_map do |root|
        next unless owned_remote?(git_remote(root))

        abcop_root_output(bin, root)
      end.join
    end

    def abcop_root_output(bin, root)
      STDERR.puts "[quality] #{root}: abcop (current-MR scope)"
      out, err, code = capture(bin, '--format', 'json', chdir: root)
      return scope_failure(err) if code == 2

      # Exit contract: 0 clean, 1 findings, 2 infra failure. Parse on every
      # other exit so a future contract change can never hide findings.
      lines = parse_abcop_json(out, err).filter_map { |d| abcop_diag_line(d, root) }
      lines.empty? ? '' : "#{lines.join("\n")}\n"
    end

    # Scope failure (bad checkout/infra): no scan ran, nothing to report —
    # surface the reason for observability.
    def scope_failure(err)
      STDERR.puts "[quality] abcop scope failed: #{err[0, 200]}"
      ''
    end

    def parse_abcop_json(out, err)
      JSON.parse(out)['diagnostics'] || []
    rescue StandardError
      STDERR.puts "[quality] abcop output unreadable: #{err[0, 200]}"
      []
    end

    def abcop_diag_line(diag, root)
      rel = diag['file'].sub(%r{\A#{Regexp.escape(root)}/}, '')
      "#{rel}:#{diag['line']}:#{diag['column']}: " \
        "#{diag['severity']}: #{diag['rule']}: #{diag['message']}"
    end
  end
end
