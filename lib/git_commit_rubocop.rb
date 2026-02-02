# frozen_string_literal: true

require "oj"
require "shellwords"
require "colorize"

# Runs rubocop, lets user select warnings to fix, and invokes agent to fix them.
module GitCommitRubocop
  module_function

  def handle_rubocop_warnings
    return false unless check_agent_installed

    warnings = run_rubocop_warnings
    return false if warnings.empty?

    display_rubocop_warnings(warnings)
    selection = get_warning_selection(warnings)

    return false if selection == []

    if selection == :consecutive
      fix_warnings_consecutively(warnings)
    else
      fix_warnings_by_indices(warnings, selection)
    end

    check_remaining_warnings
    true
  end

  def check_agent_installed
    system("agent --version > #{File::NULL} 2>&1")
  end

  def run_rubocop_warnings
    output = `rubocop --format json 2>/dev/null`
    return [] unless $?.success?

    result = Oj.load(output)
    offenses = result["files"]&.flat_map { |file| file["offenses"] || [] } || []
    offenses.map do |offense|
      {
        "file" => offense["location"]["file_path"],
        "line" => offense["location"]["start_line"],
        "cop" => offense["cop_name"],
        "message" => offense["message"],
        "severity" => offense["severity"]
      }
    end
  rescue Oj::ParseError
    []
  end

  def display_rubocop_warnings(warnings)
    return if warnings.empty?

    puts "\nRubocop warnings:".yellow
    warnings.each_with_index { |warning, idx| display_single_rubocop_warning(warning, idx) }
    puts
  end

  def get_warning_selection(warnings)
    return [] if warnings.empty?

    display_warning_selection_prompt
    input = PromptReader.read_line("", downcase: true)
    parse_selection_input(input, warnings.size)
  end

  def fix_warning_with_agent(warning)
    prompt = build_warning_prompt(warning)
    cmd = ["agent", "--print", "--output-format", "stream-json", prompt].map { |arg|
      Shellwords.escape(arg)
    }.join(" ")
    puts "Running: #{cmd}".green
    system(cmd)
  end

  def fix_all_warnings_with_agent(selected_warnings)
    prompt = build_all_warnings_prompt(selected_warnings)
    display_warnings_summary(selected_warnings)
    cmd = ["agent", "--print", "--output-format", "stream-json", prompt].map { |arg|
      Shellwords.escape(arg)
    }.join(" ")
    puts "Running: agent --print [prompt]".green
    system(cmd)
  end

  def display_single_rubocop_warning(warning, idx)
    file = warning["file"]
    line = warning["line"]
    cop = warning["cop"]
    message = warning["message"]
    severity = warning["severity"]
    severity_color = severity == "error" ? :red : :yellow
    puts "  [#{idx + 1}] #{file}:#{line} - #{cop}".colorize(severity_color)
    puts "      #{message}".yellow
  end

  def display_warning_selection_prompt
    puts "Select warnings to fix:".white
    puts "  - Enter numbers separated by spaces (e.g., '1 3 5')".white
    puts "  - Enter 'all' to fix all warnings".white
    puts "  - Enter 'consecutive' to fix warnings one by one".white
    puts "  - Enter 'skip' to skip fixing warnings".white
  end

  def display_warnings_summary(selected_warnings)
    puts "Fixing #{selected_warnings.size} warning(s) at once...".cyan
    puts "Warnings to fix:".yellow
    selected_warnings.each_with_index do |warning, idx|
      puts "  #{idx + 1}. #{warning['file']}:#{warning['line']} - #{warning['cop']}".yellow
    end
  end

  def display_consecutive_warning(warning, idx, total)
    puts "\nWarning #{idx + 1}/#{total}: #{warning['file']}:#{warning['line']} - #{warning['cop']}".cyan
    puts "  #{warning['message']}".yellow
  end

  def build_warning_prompt(warning)
    file = warning["file"]
    line = warning["line"]
    cop = warning["cop"]
    message = warning["message"]

    "Fix the following Rubocop warning in #{file} at line #{line}:\n" \
      "Cop: #{cop}\n" \
      "Message: #{message}\n" \
      "Fix only this specific warning without changing other code."
  end

  def build_all_warnings_prompt(selected_warnings)
    prompt_parts = ["Fix the following Rubocop warnings:\n"]
    selected_warnings.each_with_index do |warning, idx|
      file = warning["file"]
      line = warning["line"]
      cop = warning["cop"]
      message = warning["message"]
      prompt_parts << "#{idx + 1}. #{file}:#{line} - #{cop}"
      prompt_parts << "   Message: #{message}\n"
    end
    prompt_parts << "\nFix all these warnings without changing other code."
    prompt_parts.join("\n")
  end

  def parse_selection_input(input, warnings_size)
    return [] if input == "skip"
    return (0...warnings_size).to_a if input == "all"
    return :consecutive if input == "consecutive"

    parse_warning_indices(input, warnings_size)
  end

  def parse_warning_indices(input, warnings_size)
    input.split.map(&:to_i).select { |n| n >= 1 && n <= warnings_size }.map { |n| n - 1 }.uniq
  end

  def should_fix_warning?
    puts "Fix this warning? (y/N/skip)".white
    answer = PromptReader.read_line("", downcase: true)
    return :skip if answer == "skip"
    return :yes if answer == "y"

    :no
  end

  def fix_warnings_consecutively(warnings)
    warnings.each_with_index do |warning, idx|
      display_consecutive_warning(warning, idx, warnings.size)
      decision = should_fix_warning?
      break if decision == :skip
      next if decision == :no

      fix_warning_with_agent(warning)
    end
  end

  def fix_warnings_by_indices(warnings, selected_indices)
    selected_warnings = selected_indices.map { |idx| warnings[idx] }
    fix_all_warnings_with_agent(selected_warnings)
  end

  def check_remaining_warnings
    puts "\nRe-checking rubocop warnings...".cyan
    remaining_warnings = run_rubocop_warnings
    if remaining_warnings.any?
      puts "Remaining warnings: #{remaining_warnings.size}".yellow
      display_rubocop_warnings(remaining_warnings)
    else
      puts "All selected warnings fixed!".green
    end
  end
end
