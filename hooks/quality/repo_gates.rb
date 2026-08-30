# frozen_string_literal: true

require 'json'

module Quality
  # Last-remaining-agent gate by reading Cursor/omp session logs — no lock files.
  # A session is finished when its log ends with an end marker (Cursor: turn_ended;
  # omp: customType session_exit). Gate opens when every other session for this
  # project is finished or older than SESSION_OPEN_AGE; only the current session
  # may still be unfinished. Cursor may not refresh transcript mtime until the
  # turn ends, so unfinished logs use SESSION_OPEN_AGE rather than a tiny idle cut.
  module RepoGates
    def sole_session?(root)
      siblings = open_sibling_sessions(root)
      return true if siblings.empty?

      log_action('skip', reason: 'other_sessions', others: siblings.first(5).join(','))
      STDERR.puts "[quality] skip: other sessions still open (#{siblings.size}): #{siblings.first(3).join(', ')}"
      false
    end

    private

    def open_sibling_sessions(root)
      (cursor_open_sessions + omp_open_sessions(root)).uniq
    end

    def cursor_open_sessions
      base = cursor_transcripts_root
      return [] unless base && File.directory?(base)

      Dir.children(base).filter_map do |sid|
        next if sid == @session_key || sid.start_with?('.')

        path = File.join(base, sid, "#{sid}.jsonl")
        next unless open_session_file?(path) { |o| o['type'] == 'turn_ended' }

        "cursor:#{sid}"
      end
    rescue StandardError
      []
    end

    def omp_open_sessions(root)
      dir = omp_sessions_dir(root)
      return [] unless dir && File.directory?(dir)

      Dir.glob(File.join(dir, '*.jsonl')).filter_map { |path| omp_open_label(path, root) }
    rescue StandardError
      []
    end

    def omp_open_label(path, root)
      sid = omp_session_id(path)
      return if sid.empty? || sid == @session_key || File.basename(path).start_with?('__')
      return unless omp_session_cwd?(path, root)
      return unless open_session_file?(path) { |o| o['type'] == 'custom' && o['customType'] == 'session_exit' }

      "omp:#{sid}"
    end

    # True when the log exists, is not past the open TTL, and does not end with
    # the finished-session marker from the block.
    def open_session_file?(path)
      return false unless File.file?(path)
      return false if Time.now.to_i - File.mtime(path).to_i >= SESSION_OPEN_AGE
      return false if jsonl_ends_with?(path) { |o| yield o }

      true
    end

    def cursor_transcripts_root
      path = @transcript_path.to_s
      return nil if path.empty?

      # .../agent-transcripts/<id>/<id>.jsonl
      parent = File.dirname(path)
      root = File.dirname(parent)
      File.basename(root) == 'agent-transcripts' ? root : nil
    end

    # ~/.omp/agent/sessions/<slug>: home paths → -ruby-refactor_gpt;
    # outside home → --private-tmp-calc-- (macOS /private/tmp normalized).
    def omp_sessions_dir(root)
      return nil if root.to_s.empty?

      home = ENV['HOME'].to_s
      abs = omp_path_key(root)
      slug =
        if !home.empty? && abs.start_with?(home + '/')
          abs[home.length..].gsub('/', '-')
        else
          "--private-#{abs.sub(%r{\A/}, '').gsub('/', '-')}--"
        end
      File.join(home, '.omp/agent/sessions', slug)
    end

    def omp_path_key(root)
      abs = File.expand_path(root)
      abs = abs.delete_prefix('/private') if abs.start_with?('/private/tmp')
      abs
    end

    def omp_session_id(path)
      base = File.basename(path, '.jsonl')
      # 2026-08-26T21-02-14-487Z_01a03fe1-71d7-710c-9bb0-38139d518edd
      base.include?('_') ? base.split('_', 2).last.to_s : base
    end

    def omp_session_cwd?(path, root)
      want = omp_path_key(root)
      each_jsonl_head(path, 8) do |o|
        next unless o['type'] == 'session'

        cwd = o['cwd'].to_s
        return cwd.empty? || omp_path_key(cwd) == want
      end
      false
    end

    def jsonl_ends_with?(path)
      obj = last_jsonl_object(path)
      obj && yield(obj)
    end

    def last_jsonl_object(path)
      size = File.size(path)
      return nil if size.zero?

      File.open(path, 'rb') do |f|
        f.seek([size - 16_384, 0].max)
        lines = f.read.to_s.split(/\n/)
        lines.reverse_each do |line|
          line = line.strip
          next if line.empty?

          return JSON.parse(line)
        rescue JSON::ParserError
          next
        end
      end
      nil
    rescue StandardError
      nil
    end

    def each_jsonl_head(path, limit)
      n = 0
      File.foreach(path) do |line|
        line = line.strip
        next if line.empty?

        yield JSON.parse(line)
        n += 1
        break if n >= limit
      rescue JSON::ParserError
        next
      end
    end
  end
end
