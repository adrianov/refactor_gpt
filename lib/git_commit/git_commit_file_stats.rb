# frozen_string_literal: true

require "shellwords"

# Reads fallback per-file statistics when batch numstat has no entry.
module GitCommitFileStats
  def get_single_file_stats(file)
    path = file.to_s.strip
    return "" if path.empty?

    status = `git status --porcelain #{Shellwords.escape(path)} 2>/dev/null`.strip
    return get_modified_file_stats(path) unless $?.success?

    case status
    when /^D /, /^ D/ then get_deleted_file_stats(path)
    when /^A/ then get_added_file_stats(path)
    when /^\?\?/ then get_new_file_stats(path)
    else get_modified_file_stats(path)
    end
  end

  def get_added_file_stats(file)
    line_count = count_file_lines(file)
    line_count.positive? ? "#{line_count}+0-" : ""
  end

  def get_new_file_stats(file)
    get_added_file_stats(file)
  end

  def get_deleted_file_stats(file)
    deleted_lines = get_deleted_file_line_count(file)
    deleted_lines.positive? ? "0+#{deleted_lines}-" : ""
  end

  def get_modified_file_stats(file)
    escaped = Shellwords.escape(file)
    get_stat_from_numstat("git diff --cached --numstat -- #{escaped}") ||
      get_stat_from_numstat("git diff --numstat -- #{escaped}") ||
      get_stat_from_command("git diff --cached --stat -- #{escaped}") ||
      get_stat_from_command("git diff --stat -- #{escaped}")
  end

  def get_stat_from_numstat(command)
    out = `#{command} 2>/dev/null`.strip
    $?.success? && out.lines.any? ? parse_numstat_line(out.lines.first) : ""
  end

  def parse_numstat_line(line)
    add_str, del_str = line.strip.split("\t", 3).first(2)
    return "" if add_str.nil? || del_str.nil? || add_str == "-" || del_str == "-"

    add = add_str.to_i
    delete = del_str.to_i
    (add + delete).positive? ? "#{add}+#{delete}-" : ""
  end

  def get_stat_from_command(command)
    stat_output = `#{command} 2>/dev/null`
    return "" unless $?.success?

    line = stat_output.lines.find { |entry| !summary_line?(entry) }
    line ? process_stat_line_for_file(line) : ""
  end

  def count_file_lines(file)
    File.exist?(file) ? File.readlines(file).size : 0
  rescue StandardError
    0
  end

  def get_deleted_file_line_count(file)
    output = `git show HEAD:#{Shellwords.escape(file)} 2>/dev/null`
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
    return "" unless total_changes.positive?
    return "#{total_changes}+0-" if plus_minus.empty?

    "#{plus_minus.count("+")}+#{plus_minus.count("-")}-"
  end
end
