# frozen_string_literal: true

require "reline"

# Shared helpers for reading a single line from the user (Reline).
module PromptReader
  MULTILINE_PROMPT = "> "

  def self.read_line(prompt = "", downcase: false)
    line = (Reline.readline(prompt) || "").to_s.strip
    downcase ? line.downcase : line
  end

  def self.multiline_prompt(_lines_empty)
    MULTILINE_PROMPT
  end
end
