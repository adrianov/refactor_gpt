# frozen_string_literal: true

require 'json'

module Quality
  # Transcript helpers: recent user texts detect followup chains; outgoing
  # text is shown relative to workspace roots. Changed files come from
  # Quality::GitChanges (git-diff), which never parses the transcript.
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
  end
end
