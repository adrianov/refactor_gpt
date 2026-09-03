# frozen_string_literal: true

# Preserves structural boundaries and emits context skip markers for compacted diffs.
module DiffCompactorMarkers
  private

  def structural_boundary?(line)
    content = extract_line_content(line)
    return false if content.nil? || content.empty?

    text = content.to_s.strip
    text.start_with?("class ", "module ") || text == "end"
  end

  def extract_line_content(line)
    return line[1..] if line.start_with?(" ", "+", "-")

    line
  end

  def preserve_boundary_line(line, state)
    key = state[:in_changes] ? :trailing_boundaries : :leading_boundaries
    state[key] << line
  end

  def add_trailing_context(line, state, max_context)
    if state[:trailing_context].size < max_context
      state[:trailing_context] << line
    else
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
    format_skip_marker(first_skipped, first_skipped + excess - 1, excess)
  end

  def flush_leading_context_with_boundaries(state, max_context)
    return if state[:leading_context].empty? && state[:leading_boundaries].empty?

    concat_and_clear(state, :leading_boundaries)
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
    state[:result] << format_skip_marker(first_skipped, first_skipped + skipped - 1, skipped)
  end

  def flush_leading_context_lines(state, max_context)
    lines = state[:leading_context]
    state[:result].concat(lines.size > max_context ? lines.last(max_context) : lines)
  end

  def flush_context_buffers(state)
    %i[leading_boundaries leading_context trailing_boundaries trailing_context].each do |key|
      concat_and_clear(state, key)
    end
    emit_trailing_skip_marker_if_present(state)
  end

  def concat_and_clear(state, key)
    state[:result].concat(state[key])
    state[key] = []
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
    emit_trailing_skip_marker_if_present(state)
  end

  def finalize_trailing_empty?(state)
    state[:trailing_context].empty? && state[:trailing_boundaries].empty? && !state[:trailing_skipped_count]
  end

  def emit_trailing_skip_marker_if_present(state)
    return unless state[:trailing_skipped_count] && state[:trailing_skipped_count].positive?

    state[:result] << format_skip_marker(
      state[:trailing_skipped_start], state[:trailing_skipped_end], state[:trailing_skipped_count]
    )
    state[:trailing_skipped_count] = 0
  end

  def format_skip_marker(start_line, end_line, count)
    " ... (skipped #{count} lines: #{start_line}-#{end_line}) ...\n"
  end
end
