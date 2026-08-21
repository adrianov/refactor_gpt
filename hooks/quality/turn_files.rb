# frozen_string_literal: true

require 'json'

module Quality
  # Transcript and tool-path collection for the current turn and session.
  module TurnFiles
    def parent_messages
      @parent_messages ||= load_jsonl(@transcript_path)
    end
    def all_messages
      @all_messages ||= session_transcript_files.flat_map { |f| load_jsonl(f) }
    end
    def load_jsonl(path)
      return [] if path.to_s.empty? || !File.file?(path)

      File.foreach(path).with_object([]) do |line, msgs|
        line = line.strip
        next if line.empty?

        obj = begin
          JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        msgs << obj if obj.is_a?(Hash) && obj.key?('role')
      end
    end
    def session_transcript_files
      files = []
      files << @transcript_path if File.file?(@transcript_path.to_s)
      dir = File.dirname(@transcript_path.to_s)
      Dir.glob(File.join(dir, 'subagents', '*.jsonl')).each { |f| files << f if File.file?(f) }
      files
    end
    def content_items(msg)
      c = msg.is_a?(Hash) ? (msg.dig('message', 'content') || []) : []
      c.is_a?(Array) ? c : []
    end
    def last_user_index(msgs)
      idx = nil
      msgs.each_with_index { |m, i| idx = i if m['role'] == 'user' }
      idx
    end
    def last_user_text
      i = last_user_index(parent_messages)
      return '' if i.nil?

      content_items(parent_messages[i]).select { |c| c['type'] == 'text' }.map { |c| c['text'].to_s }.join("\n")
    end
    def this_turn_tools
      msgs = parent_messages
      i = last_user_index(msgs)
      return [] if i.nil?

      msgs[(i + 1)..-1].flat_map { |m| content_items(m) }.select do |c|
        c.is_a?(Hash) && c['type'] == 'tool_use' && !READONLY.include?(c['name'].to_s)
      end
    end
    def this_turn_shell_commands
      this_turn_tools.select { |t| t['name'] == 'Shell' }.map { |t| (t.dig('input', 'command') || '').to_s }
    end
    def this_turn_files
      this_turn_tools.flat_map { |t| tool_paths(t) }.select { |p| keep_path?(p) }.map { |p| abs_path(p) }.uniq
    end
    def session_modifying_paths
      paths = modifying_tool_paths(all_messages)
      rec = session_files_record
      File.foreach(rec) { |line| paths << line.chomp unless line.strip.empty? } if rec && File.file?(rec)
      paths.uniq
    end
    def modifying_tool_paths(msgs)
      msgs.flat_map { |m| content_items(m) }.flat_map do |c|
        next [] unless c.is_a?(Hash) && c['type'] == 'tool_use'
        next [] if READONLY.include?(c['name'].to_s)

        tool_paths(c).select { |p| keep_path?(p) }.map { |p| abs_path(p) }
      end
    end
    def tool_paths(tool)
      name = tool['name'].to_s
      input = tool['input']
      return shell_write_paths(input.is_a?(Hash) ? input : {}) if name == 'Shell'
      return apply_patch_files(input) if input.is_a?(String)
      return object_file_paths(input) if input.is_a?(Hash)

      []
    end
    def path_keys_from(input)
      paths = []
      %w[path file_path target_notebook filename old_path new_path downloadPath download_path].each do |k|
        v = input[k]
        paths << v if v.is_a?(String) && !v.empty?
      end
      Array(input['paths']).each { |p| paths << p if p.is_a?(String) && !p.empty? }
      paths
    end
    def object_file_paths(input)
      (path_keys_from(input) + apply_patch_files((input['patch'] || input['diff']).to_s)).uniq
    end
    def apply_patch_files(str)
      str.to_s.scan(/\*\*\* (?:Update|Add|Delete) File: ([^\n]+)/).flatten.map(&:strip).reject(&:empty?)
    end
    def shell_write_paths(input)
      c = input['command'].to_s
      wd = input['working_directory'].to_s
      paths = []
      paths << shell_rel(wd, 'db/schema.rb') if c =~ SCHEMA_SHELL_RE
      git_write_paths(c).each { |p| paths << shell_rel(wd, p) }
      paths.uniq
    end
    def shell_rel(wd, p)
      return nil if p.to_s.empty?
      return p if p.start_with?('/')
      return "#{wd}/#{p}" unless wd.empty?

      p
    end
    def git_write_paths(cmd)
      git_mv_paths(cmd) + git_rm_paths(cmd)
    end
    def git_mv_paths(cmd)
      paths = []
      cmd.scan(/git[[:space:]]+mv#{GIT_FLAGS}[[:space:]]+(\S+)[[:space:]]+(\S+)/) do |a, b|
        paths << unquote_token(a) << unquote_token(b)
      end
      paths
    end
    def git_rm_paths(cmd)
      paths = []
      cmd.scan(/(?:git[[:space:]]+rm|rm(?:dir)?)#{GIT_FLAGS}[[:space:]]+([^\n;&|]+)/) do |rest|
        chunk = rest.is_a?(Array) ? rest.first : rest
        chunk.to_s.split(/[[:space:]]+/).each do |tok|
          t = unquote_token(tok)
          next if t.empty? || t == '--' || t.start_with?('-')

          paths << t
        end
      end
      paths
    end
    def unquote_token(s)
      s = s.to_s
      quoted = (s.start_with?('"') && s.end_with?('"')) || (s.start_with?("'") && s.end_with?("'"))
      quoted && s.length > 1 ? s[1..-2] : s
    end
    def abs_path(p)
      p.to_s.empty? || p.start_with?('/') ? p : (@roots.empty? ? p : "#{@roots[0]}/#{p}")
    end
    def hook_file?(p)
      a = abs_path(p)
      a == HOOKS || a.start_with?("#{HOOKS}/") || a == File.join(File.dirname(HOOKS), 'hooks.json')
    end
    def keep_path?(p)
      a = abs_path(p)
      !a.to_s.empty? && !hook_file?(a) && (in_workspace?(a) || !temp?(a))
    end
    def in_workspace?(p)
      @roots.any? { |r| p == r || p.start_with?("#{r}/") }
    end
    def temp?(p)
      p =~ %r{^(/private)?/tmp/} || (!@tmpdir.empty? && (p == @tmpdir || p.start_with?("#{@tmpdir}/")))
    end
    def rel_project_text(text)
      project_roots.each { |r| text = text.split("#{r}/").join('').split(r).join('.') unless r.empty? }
      text
    end
    def project_roots
      rs = @roots.reject(&:empty?).uniq.sort_by { |r| -r.length }
      rs.empty? && ENV['CURSOR_PROJECT_DIR'] ? [ENV['CURSOR_PROJECT_DIR'].to_s.sub(%r{/$}, '')] : rs
    end
  end
end
