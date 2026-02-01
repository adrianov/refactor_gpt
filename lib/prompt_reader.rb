# frozen_string_literal: true

require "reline"

# Shared helpers for reading input from the user via Reline (single line or multiline).
module PromptReader
  MULTILINE_PROMPT = "> "

  def self.read_line(prompt = "", downcase: false)
    line = (Reline.readline(prompt) || "").to_s.strip
    downcase ? line.downcase : line
  end

  def self.multiline_prompt(_lines_empty)
    MULTILINE_PROMPT
  end

  # Reads lines until user submits an empty line or EOF. Returns joined text or nil.
  def self.read_multiline
    lines = []
    loop do
      line = Reline.readline(multiline_prompt(lines.empty?), true)
      return nil if line.nil?

      line = line.strip
      if line.empty?
        break unless lines.empty?

        return nil
      end
      lines << line
    end
    lines.join("\n")
  end
end
