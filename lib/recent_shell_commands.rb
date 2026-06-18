# frozen_string_literal: true

# Reads the last few commands from zsh or bash shell history for git_commit_gpt context.
module RecentShellCommands
  module_function

  def last_few(count = 5)
    history_file = detect_history_file
    return "" unless history_file && File.exist?(history_file)

    lines = read_history_file(history_file)
    return "" if lines.empty?

    extract_commands_from_history(lines, history_file).last(count).join("\n")
  end

  def read_history_file(history_file)
    File.readlines(history_file, chomp: true, encoding: "UTF-8")
  rescue ArgumentError
    File.readlines(history_file, chomp: true).select { |line| line.valid_encoding? }
  end

  def detect_history_file
    return ENV["HISTFILE"] if ENV["HISTFILE"] && File.exist?(ENV["HISTFILE"])

    zsh_history = File.expand_path("~/.zsh_history")
    return zsh_history if File.exist?(zsh_history)

    bash_history = File.expand_path("~/.bash_history")
    return bash_history if File.exist?(bash_history)

    nil
  end

  def extract_commands_from_history(lines, history_file)
    if history_file.include?("zsh_history")
      lines.filter_map do |line|
        next unless line.valid_encoding?

        stripped = line.sub(/^: \d+:\d+;/, "")
        stripped.empty? ? nil : stripped
      end
    else
      lines.select { |line| line.valid_encoding? }
    end
  end
  private_class_method :read_history_file, :detect_history_file, :extract_commands_from_history
end
