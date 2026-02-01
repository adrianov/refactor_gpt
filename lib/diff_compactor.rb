# frozen_string_literal: true

class DiffCompactor
  def compact(diff_content, max_bytes)
    return nil if max_bytes <= 0

    lines = diff_content.lines
    return nil if lines.empty?

    compacted = compact_diff_hunks(lines, max_bytes)
    return nil unless compacted

    result = compacted.join
    result.bytesize <= max_bytes ? result : nil
  end

  private

  def compact_diff_hunks(lines, max_bytes)
    [10, 5, 3, 1, 0].each do |context|
      result = build_compacted_diff(lines, context)
      next unless result

      result_size = result.join.bytesize
      return result if result_size <= max_bytes
    end

    # If even context=0 is too large, try one more time with a very aggressive approach
    # but for now we return nil as per existing logic if it doesn't fit.
    nil
  end

  def build_compacted_diff(lines, context)
    result = []
    current_hunk = []
    hunk_header = nil
    in_hunk = false

    lines.each do |line|
      if diff_header_line?(line)
        flushed = flush_hunk_if_needed(result, current_hunk, hunk_header, in_hunk, context)
        return nil if flushed.nil?
        in_hunk = false if flushed
        result << line
        if hunk_start?(line)
          hunk_header = line
          in_hunk = true
        end
        current_hunk = []
      elsif in_hunk
        current_hunk << line
      else
        result << line
      end
    end

    return nil if flush_hunk_if_needed(result, current_hunk, hunk_header, in_hunk, context).nil?
    result
  end

  def flush_hunk_if_needed(result, current_hunk, hunk_header, in_hunk, context)
    return true unless in_hunk

    compacted = compact_single_hunk(current_hunk, hunk_header, context)
    return nil unless compacted

    result.concat(compacted)
    true
  end

  def append_completed_hunk(result, current_hunk, hunk_header, in_hunk, context)
    return true unless in_hunk && !current_hunk.empty?

    compacted = compact_single_hunk(current_hunk, hunk_header, context)
    return false if compacted.nil?

    result.concat(compacted)
    true
  end

  def diff_header_line?(line)
    line.start_with?("diff --git") || line.start_with?("index ") || line.start_with?("---") ||
      line.start_with?("+++") || hunk_start?(line)
  end

  def hunk_start?(line)
    line.start_with?("@@")
  end

  def compact_single_hunk(hunk_lines, hunk_header, max_context)
    return hunk_lines if hunk_lines.empty?

    line_numbers = parse_hunk_header(hunk_header)
    return hunk_lines unless line_numbers

    state = {result: [], leading_context: [], trailing_context: [], in_changes: false,
             leading_boundaries: [], trailing_boundaries: [],
             old_line_num: line_numbers[:old_start], new_line_num: line_numbers[:new_start],
             leading_skip_marker: nil, trailing_skipped_count: 0,
             trailing_skipped_start: nil, trailing_skipped_end: nil}

    hunk_lines.each do |line|
      process_hunk_line(line, state, max_context)
    end

    finalize_hunk_context(state, max_context)
    state[:result]
  end

  def parse_hunk_header(header)
    return nil unless header&.start_with?("@@")

    match = header.match(/@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/)
    return nil unless match

    {old_start: match[1].to_i, old_count: (match[2] || 1).to_i,
     new_start: match[3].to_i, new_count: (match[4] || 1).to_i}
  end

  def process_hunk_line(line, state, max_context)
    if change_line?(line)
      update_line_numbers(line, state)
      handle_change_line(line, state, max_context)
    elsif context_line?(line)
      update_line_numbers(line, state)
      handle_context_line(line, state, max_context)
    else
      flush_context_buffers(state)
      state[:result] << line
    end
  end

  def update_line_numbers(line, state)
    if line.start_with?("+")
      state[:new_line_num] += 1
    elsif line.start_with?("-")
      state[:old_line_num] += 1
    elsif line.start_with?(" ")
      state[:old_line_num] += 1
      state[:new_line_num] += 1
    end
  end

  def change_line?(line)
    line.start_with?("+") || line.start_with?("-")
  end

  def context_line?(line)
    line.start_with?(" ")
  end

  def handle_change_line(line, state, max_context)
    if !state[:in_changes]
      flush_leading_context_with_boundaries(state, max_context)
    end
    state[:result] << line
    state[:in_changes] = true
    state[:trailing_context] = []
    state[:trailing_boundaries] = []
    state[:trailing_skipped_count] = 0
    state[:trailing_skipped_start] = nil
    state[:trailing_skipped_end] = nil
  end

  def handle_context_line(line, state, max_context)
    if structural_boundary?(line)
      preserve_boundary_line(line, state)
    elsif state[:in_changes]
      add_trailing_context(line, state, max_context)
    else
      add_leading_context(line, state, max_context)
    end
  end

  def structural_boundary?(line)
    content = extract_line_content(line)
    return false if content.nil? || content.empty?

    t = content.to_s.strip
    t.start_with?("class ", "module ") || t == "end"
  end

  def extract_line_content(line)
    return line[1..] if line.start_with?(" ", "+", "-")

    line
  end

  def preserve_boundary_line(line, state)
    if state[:in_changes]
      state[:trailing_boundaries] << line
    else
      state[:leading_boundaries] << line
    end
  end

  def add_trailing_context(line, state, max_context)
    if state[:trailing_context].size < max_context
      state[:trailing_context] << line
    else
      # We already have max_context lines, so this one and any subsequent ones are skipped
      state[:trailing_skipped_count] += 1
      state[:trailing_skipped_start] ||= state[:new_line_num]
      state[:trailing_skipped_end] = state[:new_line_num]
    end
  end

  def add_leading_context(line, state, max_context)
    state[:leading_context] << line
    return if state[:leading_context].size <= max_context

    state[:leading_skip_marker] = compute_leading_skip_marker(state, max_context)
    state[:leading_context].shift
  end

  def compute_leading_skip_marker(state, max_context)
    excess = state[:leading_context].size - max_context
    first_skipped = state[:old_line_num] - state[:leading_context].size + 1
    last_skipped = first_skipped + excess - 1
    format_skip_marker(first_skipped, last_skipped, excess)
  end

  def flush_leading_context_with_boundaries(state, max_context)
    return if state[:leading_context].empty? && state[:leading_boundaries].empty?

    state[:result].concat(state[:leading_boundaries])
    state[:leading_boundaries] = []
    flush_leading_skip_marker(state, max_context)
    flush_leading_context_lines(state, max_context)
    state[:leading_context] = []
  end

  def flush_leading_skip_marker(state, max_context)
    if state[:leading_skip_marker]
      state[:result] << state[:leading_skip_marker]
      state[:leading_skip_marker] = nil
    else
      flush_leading_skip_computed(state, max_context)
    end
  end

  def flush_leading_skip_computed(state, max_context)
    return unless state[:leading_context].size > max_context

    skipped = state[:leading_context].size - max_context
    first_skipped = state[:old_line_num] - state[:leading_context].size
    last_skipped = first_skipped + skipped - 1
    state[:result] << format_skip_marker(first_skipped, last_skipped, skipped)
  end

  def flush_leading_context_lines(state, max_context)
    state[:result].concat(
      state[:leading_context].size > max_context ? state[:leading_context].last(max_context) : state[:leading_context]
    )
  end

  def flush_context_buffers(state)
    flush_context_buffer_pairs(state, %i[leading_boundaries leading_context trailing_boundaries trailing_context])
    flush_trailing_skip_marker(state)
  end

  def flush_context_buffer_pairs(state, keys)
    keys.each_slice(2) do |a, b|
      concat_and_clear(state, a)
      concat_and_clear(state, b)
    end
  end

  def concat_and_clear(state, key)
    state[:result].concat(state[key])
    state[key] = []
  end

  def flush_trailing_skip_marker(state)
    emit_trailing_skip_marker_if_present(state)
  end

  def finalize_hunk_context(state, _max_context)
    unless state[:in_changes]
      state[:result].concat(state[:leading_boundaries])
      state[:result].concat(state[:leading_context])
      return
    end
    return if finalize_trailing_empty?(state)

    state[:result].concat(state[:trailing_boundaries])
    state[:result].concat(state[:trailing_context])
    append_trailing_skip_if_present(state)
  end

  def finalize_trailing_empty?(state)
    state[:trailing_context].empty? && state[:trailing_boundaries].empty? && !state[:trailing_skipped_count]
  end

  def append_trailing_skip_if_present(state)
    emit_trailing_skip_marker_if_present(state)
  end

  def emit_trailing_skip_marker_if_present(state)
    return unless state[:trailing_skipped_count] && state[:trailing_skipped_count] > 0

    state[:result] << format_skip_marker(
      state[:trailing_skipped_start], state[:trailing_skipped_end], state[:trailing_skipped_count]
    )
    state[:trailing_skipped_count] = 0
  end

  def format_skip_marker(start_line, end_line, count)
    " ... (skipped #{count} lines: #{start_line}-#{end_line}) ...\n"
  end
end
