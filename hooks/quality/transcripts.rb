# frozen_string_literal: true

require 'json'

module Quality
  # Transcript helpers: recent user texts detect followup chains; outgoing
  # text is shown relative to workspace roots. Cursor write-tool presence is
  # a boolean gate (no path list). Changed files still come from git-diff.
  module Transcripts
    def parent_messages
      @parent_messages ||= load_jsonl(@transcript_path)
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
    def content_items(msg)
      c = msg.is_a?(Hash) ? (msg.dig('message', 'content') || []) : []
      c.is_a?(Array) ? c : []
    end
    def recent_user_texts(limit = 3)
      texts = []
      parent_messages.reverse_each do |m|
        next unless m['role'] == 'user'

        text = content_items(m).select { |c| c['type'] == 'text' }.map { |c| c['text'].to_s }.join("\n")
        texts << text unless text.empty?
        break if texts.size >= limit
      end
      texts
    end
    def rel_project_text(text)
      project_roots.each { |r| text = text.split("#{r}/").join('').split(r).join('.') unless r.empty? }
      text
    end
    def project_roots
      rs = @roots.reject(&:empty?).uniq.sort_by { |r| -r.length }
      rs.empty? && ENV['CURSOR_PROJECT_DIR'] ? [ENV['CURSOR_PROJECT_DIR'].to_s.sub(%r{/$}, '')] : rs
    end

    def repo_write_tool?
      return true if messages_write_in_repo?(parent_messages)

      dir = File.dirname(@transcript_path.to_s)
      return false if dir.empty?

      Dir.glob(File.join(dir, 'subagents', '*.jsonl')).any? { |path| messages_write_in_repo?(load_jsonl(path)) }
    end

    def messages_write_in_repo?(msgs)
      msgs.any? { |m| content_items(m).any? { |c| write_tool_in_repo?(c) } }
    end

    def write_tool_in_repo?(item)
      return false unless item.is_a?(Hash) && item['type'] == 'tool_use'
      return false unless WRITE_TOOLS.include?(item['name'].to_s)

      write_tool_paths(item['input']).any? { |p| repo_path?(p) }
    end

    def write_tool_paths(input)
      return [] unless input.is_a?(Hash)

      %w[path file_path target_notebook].filter_map do |k|
        v = input[k]
        v if v.is_a?(String) && !v.empty?
      end
    end

    def repo_path?(p)
      base = @roots[0].to_s
      abs = base.empty? ? File.expand_path(p) : File.expand_path(p, base)
      project_roots.any? { |r| abs == r || abs.start_with?("#{r}/") }
    end
  end
end
