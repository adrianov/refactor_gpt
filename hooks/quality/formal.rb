# frozen_string_literal: true

require 'fileutils'

module Quality
  # Formal stage: RuboCop setup/run, AbcSize, lizard, long specs and modules.
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

      parts = [rubocop_report(files), abcsize_report(files), lizard_report(files),
               spec_length_report(files), module_report(files)].compact
      parts.empty? ? nil : parts.join("\n\n")
    end
    def ruby_files(files, rake: false)
      re = rake ? /\.(rb|rake)$/i : /\.rb$/i
      files.select { |f| f =~ re && File.file?(f) && f !~ %r{(^|/)db/schema\.rb$}i }
    end
    def rubocop_remaining(files, rake:, label:, args:)
      by_root = group_by_ruby_root(ruby_files(files, rake: rake))
      return nil if by_root.empty?

      rem = +''
      by_root.each do |root, rels|
        rem << (ensure_rubocop(root) ? rubocop_root_output(root, rels, label, args)
                                     : "[quality] could not install/run rubocop in #{root}\n")
      end
      rem.strip.empty? ? nil : rem
    end
    def rubocop_root_output(root, rels, label, args)
      STDERR.puts "[quality] #{root}: rubocop #{label} -- #{rels.join(' ')}"
      out, code = run_rubocop(root, *args, '--', *rels)
      STDERR.puts out
      code != 0 && !out.strip.empty? && out !~ RUBOCOP_NOISE ? "#{out}\n" : ''
    end
    def rubocop_report(files)
      rem = rubocop_remaining(files, rake: true, label: '-a --no-color', args: %w[-a --no-color])
      rem && "#{RUBOCOP_LEFT}\n\n#{truncate(rem)}"
    end
    def abcsize_report(files)
      rb = ruby_files(files).reject { |f| f =~ %r{(^|/)db/migrate/}i || routing_file?(f) }
      rem = rubocop_remaining(rb, rake: false, label: '--only Metrics/AbcSize --format quiet',
                              args: %w[--only Metrics/AbcSize --format quiet])
      rem && "#{ABC_LEFT}\n\n#{truncate(rem)}"
    end
    def lizard_report(files)
      bin = which('lizard')
      unless bin
        STDERR.puts '[quality] lizard not found on PATH; skip'
        return nil
      end
      keep = lizard_keep(lizard_python(bin), files)
      return nil if keep.empty?

      STDERR.puts "[quality] lizard -C 15 -w -i 0 -Ecpre -- #{keep.join(' ')}"
      out, err, code = capture('lizard', '-C', '15', '-w', '-i', '0', '-Ecpre', '--', *keep)
      combined = "#{out}#{err}"
      STDERR.puts combined
      code == 0 || combined.strip.empty? ? nil : "#{LIZARD_LEFT}\n\n#{truncate(combined)}"
    end
    def spec_length_report(this_turn)
      own = long_specs(this_turn.select { |f| f =~ /_spec\.rb$/i && owned_repo?(f) })
      other = other_long_specs
      msgs = [own.empty? ? nil : own_spec_msg(own), other.empty? ? nil : other_spec_msg(other)].compact
      msgs.empty? ? nil : msgs.join("\n\n")
    end
    def other_long_specs
      return [] if File.file?(File.join(STATE, "spec-length-#{@session_key}"))

      long_specs(session_spec_files.reject { |f| owned_repo?(f) })
    end
    def long_specs(files)
      files.map { |f| [line_count(f), f] }.select { |n, f| n >= MAX_LINES && File.file?(f) }.sort_by { |n, _| -n }
    end
    def session_spec_files
      session_modifying_paths.select { |f| f =~ /_spec\.rb$/i }
    end
    def own_spec_msg(own)
      report = own.map { |n, f| "- #{f} (#{n} lines)" }.join("\n")
      "Edited spec files (longest first):\n#{report}\n\n#{own[0][1]} is #{own[0][0]} lines (≥ 200). #{OWN_SPEC}"
    end
    def other_spec_msg(other)
      FileUtils.mkdir_p(STATE)
      File.write(File.join(STATE, "spec-length-#{@session_key}"), '')
      report = other.map { |n, f| "- #{f} (#{n} lines)" }.join("\n")
      "Spec files edited in this session are longer than 200 lines:\n#{report}\n\n#{OTHER_SPEC}"
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
        next unless File.file?(f) && prod_module?(f)
        next if f =~ /\.(ya?ml|css|scss|sass|slim|erb)$/i && !owned_repo?(f)

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
    def rubocop_docker_enabled?
      ENV['QUALITY_RUBOCOP_DOCKER'].to_s.match?(/\A(1|true|yes)\z/i)
    end

    # Compose project root for Docker RuboCop when QUALITY_RUBOCOP_DOCKER is set.
    # Private names come from env (no defaults that name a private app):
    #   QUALITY_RUBOCOP_DOCKER_SERVICE  — compose service (required)
    #   QUALITY_RUBOCOP_DOCKER_BASENAME — Gemfile root basename (default: service)
    #   QUALITY_RUBOCOP_DOCKER_PARENT   — parent dir name (default: app)
    #   QUALITY_RUBOCOP_DOCKER_COMPOSE  — compose file under grandparent (default: compose/app.yaml)
    def rubocop_docker_root(root)
      return nil unless rubocop_docker_enabled?
      return nil unless File.file?(File.join(root, 'Gemfile'))

      service = ENV['QUALITY_RUBOCOP_DOCKER_SERVICE'].to_s.strip
      return nil if service.empty?

      basename = ENV.fetch('QUALITY_RUBOCOP_DOCKER_BASENAME', service).to_s
      parent = ENV.fetch('QUALITY_RUBOCOP_DOCKER_PARENT', 'app').to_s
      compose_rel = ENV.fetch('QUALITY_RUBOCOP_DOCKER_COMPOSE', 'compose/app.yaml').to_s
      return nil unless File.basename(root) == basename
      return nil unless File.basename(File.dirname(root)) == parent

      grand = File.expand_path('../..', root)
      compose = File.join(grand, compose_rel)
      return nil unless File.file?(compose) && File.file?(File.join(grand, '.env'))
      return nil unless File.read(compose) =~ /^[[:space:]]*#{Regexp.escape(service)}:/

      grand
    end

    def rubocop_infra?(out)
      out.to_s =~ /Bundler::(GitError|PathError)|is not yet checked out|Could not locate Gemfile|Cannot connect to the Docker daemon|docker\.sock|no configuration file provided|No such service:|failed to read dockerfile|error while interpolating/
    end

    def docker_compose
      _, _, code = capture('docker', 'compose', 'version')
      return %w[docker compose] if code == 0
      return %w[docker-compose] if which('docker-compose')

      nil
    end

    def ensure_rubocop(root)
      return false unless File.directory?(root)
      return true if rubocop_docker_root(root) && which('docker')

      Dir.chdir(root) do
        return true if rubocop_ok?

        install_rubocop(root)
        return true if rubocop_ok?

        STDERR.puts "[quality] still cannot run rubocop after install (ruby=#{which('ruby')}, bundle=#{which('bundle')})"
        false
      end
    rescue StandardError => e
      STDERR.puts "[quality] ensure_rubocop: #{e.message}"
      false
    end
    def install_rubocop(root)
      STDERR.puts "[quality] rubocop missing for Ruby #{RUBY_VERSION} in #{root} — installing"
      try_bundle_install_rubocop
      return if rubocop_ok?

      _, _, code = capture('gem', 'install', 'rubocop', '--no-document')
      capture('gem', 'install', 'rubocop', '--no-document', '--user-install') if code != 0
      capture('rbenv', 'rehash') if which('rbenv')
    end
    def try_bundle_install_rubocop
      return unless File.file?('Gemfile') && File.read('Gemfile') =~ /gem ['"]rubocop['"]/

      STDERR.puts '[quality] bundle install'
      capture('bundle', 'install', '--quiet')
    end
    def rubocop_ok?
      bundled_rubocop_ok? || (capture('rubocop', '-v')[2] == 0)
    end
    def bundled_rubocop_ok?
      File.file?('Gemfile') && capture('bundle', 'exec', 'rubocop', '-v')[2] == 0
    end
    def run_rubocop(root, *args)
      wb = rubocop_docker_root(root)
      service = ENV['QUALITY_RUBOCOP_DOCKER_SERVICE'].to_s.strip
      dc = docker_compose if wb && which('docker') && !service.empty?
      if wb && dc
        cmd = dc + ['run', '--rm', '--no-deps', service, 'bundle', 'exec', 'rubocop'] + args
        STDERR.puts "[quality] #{root} via docker (#{wb}): #{cmd.join(' ')}"
        out, err, code = capture(*cmd, chdir: wb)
        combined = "#{out}#{err}"
        if rubocop_infra?(combined)
          STDERR.puts '[quality] infra failure; not treating as offenses'
          STDERR.puts combined
          return ['', 0]
        end
        return [combined, code]
      end

      Dir.chdir(root) do
        cmd = bundled_rubocop_ok? ? %w[bundle exec rubocop] : %w[rubocop]
        out, err, code = capture(*(cmd + args))
        ["#{out}#{err}", code]
      end
    end
    def lizard_python(bin)
      File.open(bin, 'r', &:readline).sub(/^#!/, '').split.first
    rescue StandardError
      nil
    end
    def lizard_keep(py, files)
      return [] unless py && File.executable?(py)

      out, err, code = capture(py, '-E', '-c', LIZARD_READER, stdin_data: "#{files.join("\n")}\n")
      if code != 0
        STDERR.puts "[quality] could not query lizard readers; skip #{err}"
        return []
      end
      out.split("\n").map(&:strip).select { |f| !f.empty? && File.file?(f) }
    rescue StandardError => e
      STDERR.puts "[quality] could not query lizard readers; skip #{e.message}"
      []
    end
  end
end
