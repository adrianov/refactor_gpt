# frozen_string_literal: true

require 'fileutils'

module Quality
  # Formal stage machinery plus the pre-commit abcop gate.
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

      parts = [abcop_report(files),
               spec_length_report(files), module_report(files)].compact
      parts.empty? ? nil : parts.join("\n\n")
    end
    # Pre-commit gate: rerun abcop over everything touched this cycle so fixes
    # made during review/document cannot land with lint debt.
    def abcop_stage(files, saved)
      targets = (files + saved).uniq.select { |f| File.file?(f) }
      msg = abcop_report(targets)
      return nil unless msg

      save_stage('abcop', targets)
      followup(msg)
    end
    # abcop: ABC size plus used-once/never-used variables over the changed
    # functions of each owned repo (untracked files count as fully changed).
    # ModuleSize diagnostics are dropped: module_report owns size guidance.
    def abcop_report(files)
      bin = which('abcop')
      unless bin
        STDERR.puts '[quality] abcop not found on PATH; skip'
        return nil
      end

      targets = abcop_targets(files)
      return nil if targets.empty?

      rem = abcop_by_root(bin, targets)
      rem.strip.empty? ? nil : "#{ABCOP_LEFT}\n\n#{truncate(rem)}"
    end

    def abcop_targets(files)
      files.select { |f| f =~ /\.(rb|rake|ru|rs|js|jsx|mjs|cjs|ts|tsx|mts|cts|go|swift|java|kt|kts|cs|php|sol|c|cc|cpp|cxx|h|hpp|hh|hxx)\z/i && File.file?(f) && owned_repo?(f) }
           .reject { |f| f =~ %r{(^|/)db/migrate/}i || routing_file?(f) }
    end

    # One run per repository: --mr makes abcop scan the MR scope itself
    # (changes since branching from master/main plus uncommitted work), so
    # only the repo root matters here. Result cache stays enabled — repeat
    # scans over unchanged files are cheap.
    def abcop_by_root(bin, targets)
      # abcop reports paths resolved from the git root (/tmp -> /private/tmp
      # on macOS), so match diagnostics through realpath, not expand_path.
      # Small per-turn list; Array#include? keeps this file free of the
      # `set` dependency.
      # A target deleted between turn-file collection and this scan would
      # raise ENOENT and abort the whole stage; drop it instead.
      allowed = targets.filter_map do |f|
        File.realpath(f)
      rescue Errno::ENOENT
        nil
      end
      targets.group_by { |f| git_root(File.dirname(f)) }.filter_map do |root, group|
        next if root.nil?

        abcop_root_output(bin, root, group, allowed)
      end.join
    end
    def abcop_root_output(bin, root, group, allowed)
      STDERR.puts "[quality] #{root}: abcop --mr (#{group.size} target files)"
      out, err, code = capture(bin, '--mr', '--format', 'json', chdir: root)
      return scope_failure(err) if code == 2

      # Exit contract: 0 clean, 1 findings, 2 scope/infra failure. Parse on
      # every other exit so a future contract change can never hide findings.
      lines = parse_abcop_json(out, err).filter_map { |d| abcop_diag_line(d, root, allowed) }
      lines.empty? ? '' : "#{lines.join("\n")}\n"
    end

    # Scope failure (e.g. target vanished from git): no scan ran, nothing to
    # report — surface the reason for observability.
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

    def abcop_diag_line(diag, root, allowed)
      return if diag['rule'] == 'ModuleSize' || !allowed.include?(diag['file'])

      rel = diag['file'].sub(%r{\A#{Regexp.escape(root)}/}, '')
      "#{rel}:#{diag['line']}:#{diag['column']}: " \
        "#{diag['severity']}: #{diag['rule']}: #{diag['message']}"
    end
    def spec_length_report(this_turn)
      own = long_specs(this_turn.select { |f| f =~ /_spec\.rb$/i && owned_repo?(f) })
      own.empty? ? nil : own_spec_msg(own)
    end
    def long_specs(files)
      files.map { |f| [line_count(f), f] }.select { |n, f| n >= MAX_LINES && File.file?(f) }.sort_by { |n, _| -n }
    end
    def own_spec_msg(own)
      report = own.map { |n, f| "- #{f} (#{n} lines)" }.join("\n")
      "Edited spec files (longest first):\n#{report}\n\n#{own[0][1]} is #{own[0][0]} lines (≥ 200). #{OWN_SPEC}"
    end
    def module_report(files)
      counted = counted_modules(files)
      longest = counted.find { |n, _| n >= MAX_LINES }
      return nil unless longest

      lines, file = longest
      report = counted.map { |n, f| "- #{f} (#{n} lines)" }.join("\n")
      extract, kind, drop = extract_hint(file)
      "Edited production modules (longest first):\n#{report}\n\n" \
        "#{file} is #{lines} lines (≥ 200). #{format(MODULE_SHRINK, extract: extract, kind: kind, drop: drop)}"
    end
    def counted_modules(files)
      files.each_with_object([]) do |f, a|
        next unless File.file?(f) && prod_module?(f) && owned_repo?(f)

        a << [line_count(f), f]
      end.sort_by { |n, _| -n }
    end
    def extract_hint(file)
      if file =~ /\.(ya?ml)$/i then EXTRACT_YAML
      elsif file =~ /\.(css|scss|sass)$/i then EXTRACT_CSS
      elsif file =~ /\.(slim|erb)$/i then EXTRACT_TPL
      else EXTRACT_CODE
      end
    end
  end
end
