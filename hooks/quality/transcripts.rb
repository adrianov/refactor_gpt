# frozen_string_literal: true

require 'json'

module Quality
  # Read-only transcript/text helpers left after the snapshot switch: the
  # latest user message detects followup chains, and outgoing text is shown
  # relative to the workspace roots. Changed-file tracking moved to
  # Quality::Snapshots, which never parses the transcript.
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
