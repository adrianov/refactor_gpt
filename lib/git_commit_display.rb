# frozen_string_literal: true

require "shellwords"
require "colorize"

# Renders commit plan output: warnings, excluded files, impact summary, proposed commits with file stats.
module GitCommitDisplay
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

  def get_file_stats(files, all_stats = nil)
    return {} unless files.any?

    batch = all_stats || fetch_all_numstat_stats
    stats = {}
    files.each do |file|
      path = file.to_s.strip
      stats[file] = lookup_stat(batch, path) || get_single_file_stats(path) || ""
    end
    stats
  end

  def lookup_stat(batch, path)
    batch[path] || batch[path.delete_prefix("./")] || batch["./#{path}"]
  end

  def fetch_all_numstat_stats
    cached = parse_numstat_to_hash(`git diff --cached --numstat 2>/dev/null`)
    unstaged = parse_numstat_to_hash(`git diff --numstat 2>/dev/null`)
    merge_stat_hashes(cached, unstaged)
  end

  def parse_numstat_to_hash(out)
    return {} unless out && !out.strip.empty?

    hash = {}
    out.each_line do |line|
      stat = parse_numstat_line_to_stat(line)
      hash[stat[:path]] = stat[:stat] if stat
    end
    hash
  end

  def parse_numstat_line_to_stat(line)
    add_str, del_str, path = line.strip.split("\t", 3)
    return nil if add_str.nil? || del_str.nil? || path.nil? || path.empty?
    return nil if add_str == "-" || del_str == "-"

    add = add_str.to_i
    del = del_str.to_i
    return nil unless (add + del).positive?

    { path: path.strip, stat: "#{add}+#{del}-" }
  end

  def merge_stat_hashes(cached, unstaged)
    result = cached.dup
    unstaged.each do |path, stat|
      add, del = parse_stat_string(stat)
      next unless add && del

      add = add.to_i + sum_from_stat(result[path], 0)
      del = del.to_i + sum_from_stat(result[path], 1)
      result[path] = "#{add}+#{del}-"
    end
    result
  end

  def sum_from_stat(stat_str, index)
    captures = parse_stat_string(stat_str)
    (captures && captures[index]) ? captures[index].to_i : 0
  end

  def parse_stat_string(stat)
    return nil unless stat

    stat.match(/(\d+)\+(\d+)-/)&.captures
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

  def display_planned_commits(commits)
    puts
    puts "✓ Proposed commits".green
    all_stats = fetch_all_numstat_stats
    commits.each_with_index { |commit, idx| display_single_commit(commit, idx, all_stats) }
  end

  def get_user_confirmation
    puts "Run git add/commit for the plan above? (y/N)".white
    answer = PromptReader.read_line("", downcase: true)

    unless answer == "y"
      puts "Commands not executed.".yellow
      exit 0
    end
  end

  def get_single_file_stats(file)
    path = file.to_s.strip
    return "" if path.empty?

    status = `git status --porcelain #{Shellwords.escape(path)} 2>/dev/null`.strip
    return get_modified_file_stats(path) unless $?.success?

    case status
    when /^D /, /^ D/
      get_deleted_file_stats(path)
    when /^A/
      get_added_file_stats(path)
    when /^M/, /^ M/
      get_modified_file_stats(path)
    when /^R/, /^C/
      get_modified_file_stats(path)
    when /^\?\?/
      get_new_file_stats(path)
    else
      get_modified_file_stats(path)
    end
  end

  def get_added_file_stats(file)
    line_count = count_file_lines(file)
    line_count > 0 ? "#{line_count}+0-" : ""
  end

  def get_new_file_stats(file)
    line_count = count_file_lines(file)
    line_count > 0 ? "#{line_count}+0-" : ""
  end

  def get_deleted_file_stats(file)
    deleted_lines = get_deleted_file_line_count(file)
    deleted_lines > 0 ? "0+#{deleted_lines}-" : ""
  end

  def get_modified_file_stats(file)
    get_stat_from_numstat("git diff --cached --numstat -- #{Shellwords.escape(file)}") ||
      get_stat_from_numstat("git diff --numstat -- #{Shellwords.escape(file)}") ||
      get_stat_from_command("git diff --cached --stat -- #{Shellwords.escape(file)}") ||
      get_stat_from_command("git diff --stat -- #{Shellwords.escape(file)}")
  end

  def get_stat_from_numstat(command)
    out = `#{command} 2>/dev/null`.strip
    $?.success? && out.lines.any? ? parse_numstat_line(out.lines.first) : ""
  end

  def parse_numstat_line(line)
    add_str, del_str = line.strip.split("\t", 3).first(2)
    return "" if add_str.nil? || del_str.nil? || add_str == "-" || del_str == "-"

    add = add_str.to_i
    del = del_str.to_i
    (add + del).positive? ? "#{add}+#{del}-" : ""
  end

  def display_single_commit(commit, idx, all_stats = nil)
    puts "Commit ##{idx + 1}: #{commit["message"]}".cyan
    files = Array(commit["files"])

    return puts unless files.any?

    file_stats = get_file_stats(files, all_stats)
    max_filename_length = files.map(&:length).max

    display_commit_total_stats(file_stats, files)
    files.each { |file| display_file_with_stats(file, file_stats, max_filename_length) }
    puts
  end

  def display_single_warning(warning)
    file = warning["file"].to_s
    description = warning["description"].to_s
    probability = warning["probability"]
    probability_str = probability.nil? ? "n/a" : probability.to_s
    location = format_warning_location(file, warning["start_line"], warning["end_line"])
    puts "Warning in #{location}: #{description} (probability: #{probability_str})".yellow
  end

  def display_single_excluded_file(file)
    path = file["path"].to_s
    reason = file["reason"].to_s
    puts "  - #{path}: #{reason}".magenta
  end

  def display_file_with_stats(file, file_stats, max_filename_length)
    stat_info = file_stats[file] || ""
    padding = " " * (max_filename_length - file.length)

    print "  - #{file}#{padding}".blue
    print " " unless stat_info.empty?

    if stat_info.empty?
      puts
    else
      puts format_colored_stats(stat_info)
    end
  end

  def display_commit_total_stats(file_stats, _files)
    total_additions = 0
    total_deletions = 0

    file_stats.each_value do |stat|
      next unless stat

      additions, deletions = stat.match(/(\d+)\+(\d+)-/)&.captures
      next unless additions && deletions

      total_additions += additions.to_i
      total_deletions += deletions.to_i
    end

    total_changes = total_additions + total_deletions
    puts "  Total: #{total_changes} changes (#{total_additions} additions, #{total_deletions} deletions)".yellow
  end

  def format_warning_location(file, start_line, end_line)
    return file if start_line.nil?

    if end_line.nil? || end_line == start_line
      "#{file}:#{start_line}"
    else
      "#{file}:#{start_line}-#{end_line}"
    end
  end

  def format_colored_stats(stat_info)
    additions, deletions = stat_info.match(/(\d+)\+(\d+)-/)&.captures
    return "" unless additions && deletions

    "[".white + "+#{additions}".green + " ".white + "-#{deletions}".red + "]".white
  end

  def get_stat_from_command(command)
    stat_output = `#{command} 2>/dev/null`
    return "" unless $?.success?

    output_lines = stat_output.lines.reject { |line| summary_line?(line) }
    output_lines.any? ? process_stat_line_for_file(output_lines.first) : ""
  end

  def count_file_lines(file)
    return 0 unless File.exist?(file)

    File.readlines(file).size
  rescue StandardError
    0
  end

  def get_deleted_file_line_count(file)
    show_cmd = "git show HEAD:#{Shellwords.escape(file)} 2>/dev/null"
    output = `#{show_cmd}`
    return 0 unless $?.success?

    output.lines.size
  rescue StandardError
    0
  end

  def summary_line?(line)
    line.include?("changed") || line.include?("insertion") || line.include?("deletion")
  end

  def process_stat_line_for_file(line)
    match = line.strip.match(/^\s*(.+?)\s+\|\s*(\d+)\s*([+-]+)?\s*$/)
    return "" unless match

    total_changes = match[2].to_i
    plus_minus = match[3] || ""

    return "" unless total_changes > 0

    # When git omits the +/- graph (e.g. narrow stat width), use total so we don't show 0 changes.
    if plus_minus.empty?
      return "#{total_changes}+0-"
    end

    additions = plus_minus.count("+")
    deletions = plus_minus.count("-")
    "#{additions}+#{deletions}-"
  end
end
