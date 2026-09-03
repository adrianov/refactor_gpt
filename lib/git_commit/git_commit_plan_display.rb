# frozen_string_literal: true

require "colorize"

# Renders proposed commits and their per-file change statistics.
module GitCommitPlanDisplay
  def display_planned_commits(commits)
    puts
    puts "✓ Proposed commits".green
    all_stats = fetch_all_numstat_stats
    commits.each_with_index { |commit, index| display_single_commit(commit, index, all_stats) }
  end

  def display_single_commit(commit, index, all_stats = nil)
    puts "Commit ##{index + 1}: #{commit["message"]}".cyan
    files = Array(commit["files"])
    return puts if files.empty?

    file_stats = get_file_stats(files, all_stats)
    display_commit_total_stats(file_stats, files)
    max_filename_length = files.map(&:length).max
    files.each { |file| display_file_with_stats(file, file_stats, max_filename_length) }
    puts
  end

  def display_file_with_stats(file, file_stats, max_filename_length)
    stat_info = file_stats[file] || ""
    padding = " " * (max_filename_length - file.length)
    print "  - #{file}#{padding}".blue
    print " " unless stat_info.empty?
    puts(stat_info.empty? ? nil : format_colored_stats(stat_info))
  end

  def display_commit_total_stats(file_stats, _files)
    additions, deletions = file_stats.each_value.each_with_object([0, 0]) do |stat, totals|
      captures = stat&.match(/(\d+)\+(\d+)-/)&.captures
      next unless captures

      totals[0] += captures[0].to_i
      totals[1] += captures[1].to_i
    end
    puts "  Total: #{additions + deletions} changes (#{additions} additions, #{deletions} deletions)".yellow
  end

  def format_colored_stats(stat_info)
    additions, deletions = stat_info.match(/(\d+)\+(\d+)-/)&.captures
    return "" unless additions && deletions

    "[".white + "+#{additions}".green + " ".white + "-#{deletions}".red + "]".white
  end
end
