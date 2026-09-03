# frozen_string_literal: true

require "colorize"

# Renders MR review output: summary, quality assessment, issues by severity, and suggestions.
module MrReviewDisplay
  SEVERITY_ORDER = %w[critical major minor info].freeze

  SEVERITY_COLORS = {
    "critical" => :red,
    "major" => :yellow,
    "minor" => :cyan,
    "info" => :white
  }.freeze

  SEVERITY_LABELS = {
    "critical" => "CRITICAL",
    "major" => "MAJOR",
    "minor" => "MINOR",
    "info" => "INFO"
  }.freeze

  module_function

  def display(result, branch:, base_branch:)
    puts
    puts "MR Review: #{branch} → #{base_branch}".cyan.bold
    puts ("─" * 60).cyan
    puts

    display_summary(result["summary"])
    display_quality_assessment(result["quality_assessment"])
    display_issues(result["issues"] || [])
    display_suggestions(result["suggestions"] || [])
  end

  def display_summary(summary)
    return if summary.to_s.strip.empty?

    puts "Summary:".white.bold
    puts summary.to_s.strip
    puts
  end

  def display_quality_assessment(assessment)
    return unless assessment.is_a?(Hash)

    direction = assessment["direction"]&.downcase
    explanation = assessment["explanation"].to_s.strip
    return if direction.nil? || explanation.empty?

    label = case direction
    when "increased" then "Increased".green
    when "decreased" then "Decreased".red
    else "Unchanged".yellow
    end

    puts "Quality: #{label} — #{explanation}"
    puts
  end

  def display_issues(issues)
    return if issues.empty?

    puts "Issues (#{issues.size}):".white.bold
    puts

    grouped = issues.group_by { |i| i["severity"] }
    SEVERITY_ORDER.each do |severity|
      (grouped[severity] || []).each { |issue| display_issue(issue) }
    end
  end

  def issue_header(label, color, file, start_line, end_line, title)
    location = format_location(file, start_line, end_line)
    text = location.empty? ? "[#{label}] #{title}" : "[#{label}] #{location} — #{title}"
    text.colorize(color).bold
  end

  def issue_parts(issue)
    severity = issue["severity"].to_s
    {
      color: SEVERITY_COLORS.fetch(severity, :white),
      label: SEVERITY_LABELS.fetch(severity, severity.upcase),
      description: issue["description"].to_s.strip
    }
  end

  def render_issue_body(parts, issue)
    puts issue_header(
      parts[:label], parts[:color], issue["file"].to_s,
      issue["start_line"], issue["end_line"], issue["title"].to_s
    )
    puts "  #{parts[:description].gsub("\n", "\n  ")}" unless parts[:description].empty?
    puts
  end

  def display_issue(issue)
    render_issue_body(issue_parts(issue), issue)
  end

  def display_suggestions(suggestions)
    return if suggestions.empty?

    puts "Suggestions:".white.bold
    suggestions.each_with_index do |s, i|
      puts "  #{i + 1}. #{s}"
    end
    puts
  end

  def format_location(file, start_line, end_line)
    return "" if file.empty?
    return file if start_line.nil?
    return "#{file}:#{start_line}" if end_line.nil? || end_line == start_line

    "#{file}:#{start_line}-#{end_line}"
  end
end
