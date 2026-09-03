# frozen_string_literal: true

module CursorRules
  # Reads UTF-8 rule files and `.cursor/rules/*.{mdc,md}` directories.
  module Loader
    RULES_DIR = '.cursor/rules'
    EXTENSIONS = %w[mdc md].freeze

    module_function

    def from_dir(rules_dir)
      return [] unless File.directory?(rules_dir)

      EXTENSIONS.flat_map { |ext| Dir.glob(File.join(rules_dir, '**', "*.#{ext}")) }
        .uniq.sort.filter_map { |path| read_cursor_file(path) }
    end

    def read_file(path)
      return nil unless File.file?(path)

      body = File.binread(path).force_encoding(Encoding::UTF_8).scrub('').strip
      body.empty? ? nil : body
    end

    def join_parts(parts)
      cleaned = parts.map(&:strip).reject(&:empty?)
      cleaned.empty? ? '' : cleaned.join("\n\n")
    end

    def read_cursor_file(path)
      body = read_file(path)
      return nil if body.nil?
      return body unless File.extname(path) == '.mdc' && body.start_with?('---')

      stripped = body.sub(/\A---\s*\n.*?\n---\s*\n/m, '').strip
      stripped.empty? ? body : stripped
    end
  end
end
