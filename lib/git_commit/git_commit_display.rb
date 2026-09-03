# frozen_string_literal: true

require "colorize"

# Renders commit plan output through focused display and statistics modules.
module GitCommitDisplay
  extend GitCommitFileStats
  extend GitCommitNumstatStats
  extend GitCommitPlanDisplay

  module_function

  def display_commits_result(commits, warnings, quality_assessment = nil, excluded_files = [])
    display_warnings(warnings)
    display_excluded_files(excluded_files)
    display_quality_assessment(quality_assessment) if quality_assessment
    display_planned_commits(commits)
  end

  def display_commits_and_ask(commits, warnings, quality_assessment = nil, excluded_files = [])
    display_commits_result(commits, warnings, quality_assessment, excluded_files)
    get_user_confirmation
  end

  def display_warnings(warnings)
    return if warnings.empty?

    puts "Warnings:".yellow
    warnings.each { |warning| display_single_warning(warning) }
    puts
  end

  def display_excluded_files(excluded_files)
    return if excluded_files.empty?

    puts "Excluded files:".magenta
    excluded_files.each { |file| display_single_excluded_file(file) }
    puts
  end

  def display_quality_assessment(assessment)
    direction = assessment["direction"]&.downcase
    explanation = assessment["explanation"] && assessment["explanation"].to_s.strip

    return if !direction || !explanation

    case direction
    when "increased"
      puts "Impact: #{"positive".green} — #{explanation}"
    when "decreased"
      puts "Impact: #{"negative".red} — #{explanation}"
    else
      puts "Impact: #{"neutral".yellow} — #{explanation}"
    end
    puts
  end

  def get_user_confirmation
    puts "Run git add/commit for the plan above? (y/N)".white
    unless PromptReader.read_line("", downcase: true) == "y"
      puts "Commands not executed.".yellow
      exit 0
    end
  end

  def display_single_warning(warning)
    puts(
      "Warning in #{warning_label(
        format_warning_location(warning["file"].to_s, warning["start_line"], warning["end_line"]),
        warning["category"].to_s
      )}: #{warning["description"]} (#{warning_probability(warning["probability"])})".yellow
    )
  end

  def warning_label(location, category)
    category.empty? ? location : "#{location} [#{category}]"
  end

  def warning_probability(probability)
    probability.nil? ? "n/a" : format("%.0f%%", probability.to_f * 100)
  end

  def display_single_excluded_file(file)
    puts "  - #{file["path"]}: #{file["reason"]}".magenta
  end

  def format_warning_location(file, start_line, end_line)
    return file if start_line.nil?

    if end_line.nil? || end_line == start_line
      "#{file}:#{start_line}"
    else
      "#{file}:#{start_line}-#{end_line}"
    end
  end

end
