# frozen_string_literal: true

class DiffProcessor
  CODE_EXTENSIONS = %w[
    .rb .c .h .cpp .hpp .cc .cxx .java .py .js .ts .jsx .tsx .go .rs .swift
    .kt .scala .cs .php .pl .pm .sh .bash .zsh .lua .r .m .mm .sql .graphql
    .vue .svelte .css .scss .sass .less .html .htm .xml .json .yaml .yml
    .toml .ini .conf .md .markdown .txt .rake .gemspec
  ].freeze

  def initialize(compactor: nil)
    @compactor = compactor || DiffCompactor.new
  end

  def build_sorted_diff(diff_output, status_output, max_bytes)
    return "" if diff_output.empty?

    file_diffs = parse_file_diffs(diff_output)
    return diff_output if file_diffs.empty?

    file_statuses = parse_file_statuses(status_output)
    sorted_files = sort_files_by_importance(file_diffs, file_statuses)

    included_diffs, skipped_count = collect_diffs(sorted_files, file_statuses, max_bytes)

    result = included_diffs.join("\n")
    if skipped_count > 0
      result += "\n\n... (#{skipped_count} more file(s) skipped or truncated due to size limit)\n"
    end
    result
  end

  private

  def collect_diffs(sorted_files, file_statuses, max_bytes)
    included_diffs = []
    skipped_count = 0
    current_size = 0

    sorted_files.each do |file_path, diff_content|
      current_size, skipped_count, break_loop = process_diff_entry(
        file_path, diff_content, file_statuses, current_size, max_bytes,
        included_diffs, sorted_files.size, skipped_count
      )
      break if break_loop == true
      next if break_loop == false
    end

    [included_diffs, skipped_count]
  end

  def process_diff_entry(file_path, diff_content, file_statuses, current_size, max_bytes, included_diffs,
    sorted_files_size, skipped_count)
    status = file_statuses[file_path] || "??"
    is_new_file = status.match?(/^A/) || status == "??"
    diff_size = diff_content.bytesize

    if diff_size > max_bytes
      return handle_oversized_diff(is_new_file, diff_content, current_size, max_bytes, included_diffs,
        skipped_count)
    end

    handle_normal_diff(is_new_file, diff_content, current_size, max_bytes, included_diffs, sorted_files_size,
      skipped_count)
  end

  def handle_oversized_diff(is_new_file, diff_content, current_size, max_bytes, included_diffs, skipped_count)
    remaining = max_bytes - current_size
    return [current_size, skipped_count + 1, false] if remaining <= 0

    compacted = @compactor.compact(diff_content, remaining)
    if compacted && compacted.bytesize <= remaining
      included_diffs << compacted
      [current_size + compacted.bytesize, skipped_count, false]
    elsif try_include_truncated_new_file(is_new_file, diff_content, current_size, max_bytes, included_diffs)
      [included_diffs.sum { |d| d.bytesize }, skipped_count, false]
    else
      [current_size, skipped_count + 1, false]
    end
  end

  def handle_normal_diff(is_new_file, diff_content, current_size, max_bytes, included_diffs, sorted_files_size,
    skipped_count)
    if current_size + diff_content.bytesize <= max_bytes
      included_diffs << diff_content
      current_size += diff_content.bytesize
      [current_size, skipped_count, nil]
    else
      [current_size, skipped_count, true].tap do |result|
        result[0] = handle_remaining_space(is_new_file, diff_content, current_size, max_bytes, included_diffs)
        result[1] += sorted_files_size - included_diffs.size - result[1]
      end
    end
  end

  def handle_remaining_space(is_new_file, diff_content, current_size, max_bytes, included_diffs)
    remaining = max_bytes - current_size
    return current_size if remaining <= 0

    if is_new_file
      try_include_truncated_new_file(true, diff_content, current_size, max_bytes, included_diffs)
      included_diffs.sum { |d| d.bytesize }
    else
      compacted = @compactor.compact(diff_content, remaining)
      if compacted && compacted.bytesize <= remaining
        included_diffs << compacted
        current_size + compacted.bytesize
      else
        current_size
      end
    end
  end

  def try_include_truncated_new_file(is_new_file, diff_content, current_size, max_bytes,
    included_diffs)
    return false unless is_new_file && current_size < max_bytes

    remaining = max_bytes - current_size
    truncated = truncate_file_diff(diff_content, remaining)
    return false if truncated.bytesize.zero?

    included_diffs << truncated
    true
  end

  def truncate_file_diff(diff_content, max_bytes)
    return "" if max_bytes <= 0

    truncated = diff_content.byteslice(0, max_bytes)
    last_newline = truncated.rindex("\n")
    return truncated if last_newline.nil?

    truncated.byteslice(0, last_newline + 1) + "\n... (file truncated due to size limit)\n"
  end

  def parse_file_diffs(diff_output)
    return {} if diff_output.empty?

    file_diffs = {}
    current_file = nil
    current_diff = []

    diff_output.lines.each do |line|
      if line.start_with?("diff --git")
        file_diffs[current_file] = current_diff.join if current_file
        current_file = extract_file_path_from_diff_header(line)
        current_diff = [line]
      elsif current_file
        current_diff << line
      end
    end

    file_diffs[current_file] = current_diff.join if current_file
    file_diffs
  end

  def extract_file_path_from_diff_header(line)
    return nil unless line.start_with?("diff --git ")

    rest = line.sub("diff --git ", "")
    b_index = rest.rindex(" b/")
    return nil unless b_index

    rest[(b_index + 3)..]
  end

  def parse_file_statuses(status_output)
    statuses = {}
    status_output.lines.each do |line|
      next if line.strip.empty? || line.start_with?("##")

      status_flag = line[0..1]
      file_path = line[3..]&.strip
      next if file_path.nil? || file_path.empty?

      if file_path.include?(" -> ")
        file_path = file_path.split(" -> ").last
      end

      statuses[file_path] = status_flag
    end
    statuses
  end

  def sort_files_by_importance(file_diffs, file_statuses)
    file_diffs.keys.map do |file_path|
      status = file_statuses[file_path] || "??"
      [file_path, calculate_file_score(file_path, status, file_diffs[file_path].bytesize)]
    end.sort_by { |_path, score| score }.map do |file_path, _score|
      [file_path, file_diffs[file_path]]
    end
  end

  def calculate_file_score(file_path, status, diff_size)
    status_score = status_priority(status)
    depth_score = file_path.count("/")
    extension_score = extension_priority(File.extname(file_path).downcase)
    name_length_score = File.basename(file_path).length
    size_score = diff_size / 1000

    [status_score, depth_score, extension_score, name_length_score, size_score]
  end

  def status_priority(status)
    case status
    when /M/
      1
    when /A/, "??"
      2
    when /D/
      3
    else
      4
    end
  end

  def extension_priority(ext)
    return 0 if CODE_EXTENSIONS.include?(ext)

    case ext
    when ".lock", ".sum", ".mod"
      5
    when ".log", ".tmp", ".bak"
      9
    else
      3
    end
  end
end
