# frozen_string_literal: true

# Processes changed and context lines within one unified-diff hunk.
module DiffCompactorHunks
  private

  def compact_single_hunk(hunk_lines, hunk_header, max_context)
    return hunk_lines if hunk_lines.empty?

    line_numbers = parse_hunk_header(hunk_header)
    return hunk_lines unless line_numbers

    state = {
      result: [], leading_context: [], trailing_context: [], in_changes: false,
      leading_boundaries: [], trailing_boundaries: [],
      old_line_num: line_numbers[:old_start], new_line_num: line_numbers[:new_start],
      leading_skip_marker: nil, trailing_skipped_count: 0,
      trailing_skipped_start: nil, trailing_skipped_end: nil
    }
    hunk_lines.each { |line| process_hunk_line(line, state, max_context) }
    finalize_hunk_context(state, max_context)
    state[:result]
  end

  def parse_hunk_header(header)
    return nil unless header&.start_with?("@@")

    match = header.match(/@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/)
    return nil unless match

    {
      old_start: match[1].to_i, old_count: (match[2] || 1).to_i,
      new_start: match[3].to_i, new_count: (match[4] || 1).to_i
    }
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
    flush_leading_context_with_boundaries(state, max_context) unless state[:in_changes]
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
end
