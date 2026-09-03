# frozen_string_literal: true

require 'colorize'
require 'shellwords'

# Handles refactored file writes and diff display.
class FileProcessor
  def initialize(file_codes)
    @file_codes = file_codes
  end

  def process_refactored_files(refactored_files, elapsed_time)
    log_file_counts(refactored_files)
    process_each_file(refactored_files, elapsed_time)
    report_missing_files(refactored_files)
  end

  private

  def log_file_counts(refactored_files)
    return unless @file_codes.size > 1 || refactored_files.size > 1

    warn "Expected files: #{@file_codes.keys.join(', ')}"
    warn "Parsed files: #{refactored_files.keys.join(', ')}"
  end

  def process_each_file(refactored_files, elapsed_time)
    refactored_files.each do |path, content|
      next unless @file_codes.key?(path)

      content = ensure_trailing_newline(content)
      original_code = @file_codes[path]

      display_file_stats(path, content, elapsed_time, original_code)
      next if original_code == content

      handle_file_modification(path, original_code, content)
    end
  end

  def report_missing_files(refactored_files)
    missing_files = @file_codes.keys - refactored_files.keys
    return if missing_files.empty?

    warn "No replacement content for files: #{missing_files.join(', ')}"
  end

  def ensure_trailing_newline(content)
    return content if content.empty? || content[-1] == "\n"

    "#{content}\n"
  end

  def display_file_stats(path, refactored_code, elapsed_time, original_code)
    display_basic_stats(
      path, original_code, original_code.lines.count, refactored_code, refactored_code.lines.count
    )
    display_timing_stats(refactored_code, elapsed_time)
    warn_truncation_warning(refactored_code, original_code)
  end

  def display_basic_stats(path, original_code, original_lines, refactored_code, refactored_lines)
    puts "\nFile: #{path}"
    puts "Original size: #{original_code.size} characters, #{original_lines} lines"
    puts "Refactored size: #{refactored_code.size} characters, #{refactored_lines} lines"
  end

  def display_timing_stats(refactored_code, elapsed_time)
    speed = calculate_speed(refactored_code.size, elapsed_time)
    puts "Elapsed time: #{elapsed_time.round(2)} seconds"
    puts "Speed: #{speed} characters per second"
  end

  def warn_truncation_warning(refactored_code, original_code)
    return unless refactored_code.size < original_code.size * 0.5

    warn 'Warning: Refactored code is much smaller than original (possible truncation)'
  end

  def calculate_speed(size, elapsed_time)
    return 0 unless elapsed_time.positive?

    (size / elapsed_time).round(2)
  end

  def handle_file_modification(path, original_code, refactored_code)
    is_git_repository = check_git_repository(path)
    create_backup(path, original_code) unless is_git_repository
    write_refactored_file(path, refactored_code)
    display_diff_stats(path, is_git_repository)
    display_diff(path, is_git_repository)
  end

  def display_diff_stats(path, is_git_repository)
    return unless is_git_repository

    numstat = `git diff --numstat -w #{Shellwords.shellescape(path)}`.strip
    return if numstat.empty?

    insertions, deletions = numstat.split(/\s+/).take(2)
    puts "Changes: #{"[".white}#{"+#{insertions}".green}#{" -#{deletions}".red}#{" ]".white}"
  end

  def check_git_repository(path)
    system(
      "git ls-files --error-unmatch " \
      "#{Shellwords.shellescape(path)} > #{File::NULL} 2>&1"
    )
  end

  def create_backup(path, original_code)
    backup_file_path = "#{path}.bak"
    File.binwrite(backup_file_path, original_code)
  rescue SystemCallError => e
    warn "Failed to write backup file #{backup_file_path}: #{e.message}"
    exit 1
  end

  def write_refactored_file(path, refactored_code)
    warn "Writing file: #{path} (#{refactored_code.size} bytes)"
    File.binwrite(path, refactored_code)
  rescue SystemCallError => e
    warn "Failed to write refactored file #{path}: #{e.message}"
    exit 1
  end

  def display_diff(path, is_git_repository)
    return system("git diff -w #{Shellwords.shellescape(path)}") if is_git_repository

    backup_file_path = "#{path}.bak"
    system(
      "diff -u --color #{Shellwords.shellescape(backup_file_path)} " \
      "#{Shellwords.shellescape(path)}"
    )
  end
end
