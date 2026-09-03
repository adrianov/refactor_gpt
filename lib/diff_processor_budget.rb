# frozen_string_literal: true

# Fits sorted file diffs into the available byte budget.
module DiffProcessorBudget
  private

  def collect_diffs(sorted_files, file_statuses, max_bytes)
    included = []
    skipped = 0
    current_size = 0
    sorted_files.each do |file_path, diff_content|
      current_size, skipped, stop = process_diff_entry(
        file_path, diff_content, file_statuses, current_size, max_bytes,
        included, sorted_files.size, skipped
      )
      break if stop
    end
    [included, skipped]
  end

  def process_diff_entry(file_path, diff_content, file_statuses, current_size, max_bytes, included, total, skipped)
    status = file_statuses[file_path] || "??"
    new_file = status.match?(/^A/) || status == "??"
    if diff_content.bytesize > max_bytes
      return handle_oversized_diff(new_file, code_file?(file_path), diff_content, current_size, max_bytes,
        included, skipped)
    end

    handle_normal_diff(new_file, code_file?(file_path), diff_content, current_size, max_bytes, included,
      total, skipped)
  end

  def handle_oversized_diff(new_file, code_file, diff_content, current_size, max_bytes, included, skipped)
    remaining = max_bytes - current_size
    return [current_size, skipped + 1, false] if remaining <= 0

    compacted = @compactor.compact(diff_content, remaining)
    if compacted && compacted.bytesize <= remaining
      included << compacted
      [current_size + compacted.bytesize, skipped, false]
    elsif try_include_truncated(new_file || code_file, diff_content, current_size, max_bytes, included)
      [included.sum(&:bytesize), skipped, false]
    else
      [current_size, skipped + 1, false]
    end
  end

  def handle_normal_diff(new_file, code_file, diff_content, current_size, max_bytes, included, total, skipped)
    if current_size + diff_content.bytesize <= max_bytes
      included << diff_content
      [current_size + diff_content.bytesize, skipped, nil]
    else
      size = handle_remaining_space(new_file, code_file, diff_content, current_size, max_bytes, included)
      [size, skipped + total - included.size - skipped, true]
    end
  end

  def handle_remaining_space(new_file, code_file, diff_content, current_size, max_bytes, included)
    remaining = max_bytes - current_size
    return current_size if remaining <= 0

    if new_file || code_file
      try_include_truncated(true, diff_content, current_size, max_bytes, included)
      included.sum(&:bytesize)
    else
      compacted = @compactor.compact(diff_content, remaining)
      return current_size unless compacted && compacted.bytesize <= remaining

      included << compacted
      current_size + compacted.bytesize
    end
  end

  def try_include_truncated(allow_truncate, diff_content, current_size, max_bytes, included)
    return false unless allow_truncate && current_size < max_bytes

    truncated = truncate_file_diff(diff_content, max_bytes - current_size)
    return false if truncated.bytesize.zero?

    included << truncated
    true
  end

  def truncate_file_diff(diff_content, max_bytes)
    return "" if max_bytes <= 0

    keep_len, at_line_boundary = truncation_boundary(diff_content, max_bytes)
    result = diff_content.byteslice(0, keep_len)
    result += FILE_TRUNCATION_SUFFIX if at_line_boundary
    result
  end

  def truncation_boundary(content, max_bytes)
    slice = content.byteslice(0, max_bytes)
    last_newline = slice.rindex("\n")
    return [last_newline + 1, content.bytesize > max_bytes] if last_newline

    boundary_when_no_newline(slice, content.bytesize, max_bytes)
  end

  def boundary_when_no_newline(slice, content_bytesize, max_bytes)
    return [slice.bytesize, false] if content_bytesize <= max_bytes
    return [0, content_bytesize.positive?] if slice.bytesize <= MAX_LINE_BEFORE_MID_CUT

    kept = mid_line_cut_byte_len(slice) || max_bytes
    [kept, content_bytesize > kept]
  end

  def mid_line_cut_byte_len(slice)
    last_ws = slice.rindex(/\s/)
    return last_ws + 1 if last_ws

    slice.rindex(/[^a-zA-Z0-9_\s]/)&.+(1)
  end
end
