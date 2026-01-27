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

    nil
  end

  def build_compacted_diff(lines, context)
    result = []
    current_hunk = []
    in_hunk = false

    lines.each do |line|
      if diff_header_line?(line)
        return nil unless append_completed_hunk(result, current_hunk, in_hunk, context)
        result << line
        in_hunk = hunk_start?(line)
        current_hunk = []
      elsif in_hunk
        current_hunk << line
      else
        result << line
      end
    end

    return nil unless append_completed_hunk(result, current_hunk, in_hunk, context)
    result
  end

  def append_completed_hunk(result, current_hunk, in_hunk, context)
    return true unless in_hunk && !current_hunk.empty?

    compacted = compact_single_hunk(current_hunk, context)
    return false if compacted.nil?

    result.concat(compacted)
    true
  end

  def diff_header_line?(line)
    line.start_with?("diff --git") || line.start_with?("index ") || line.start_with?("---") ||
      line.start_with?("+++") || line.start_with?("@@")
  end

  def hunk_start?(line)
    line.start_with?("@@")
  end

  def compact_single_hunk(hunk_lines, max_context)
    return hunk_lines if hunk_lines.empty?

    state = {result: [], leading_context: [], trailing_context: [], in_changes: false}

    hunk_lines.each do |line|
      process_hunk_line(line, state, max_context)
    end

    finalize_hunk_context(state, max_context)
    state[:result]
  end

  def process_hunk_line(line, state, max_context)
    if change_line?(line)
      handle_change_line(line, state, max_context)
    elsif context_line?(line)
      handle_context_line(line, state, max_context)
    else
      flush_context_buffers(state)
      state[:result] << line
    end
  end

  def change_line?(line)
    line.start_with?("+") || line.start_with?("-")
  end

  def context_line?(line)
    line.start_with?(" ")
  end

  def handle_change_line(line, state, max_context)
    if !state[:in_changes] && state[:leading_context].size > max_context
      state[:result].concat(state[:leading_context].last(max_context))
      state[:leading_context] = []
    end
    state[:result] << line
    state[:in_changes] = true
    state[:trailing_context] = []
  end

  def handle_context_line(line, state, max_context)
    if state[:in_changes]
      add_trailing_context(line, state, max_context)
    else
      add_leading_context(line, state, max_context)
    end
  end

  def add_trailing_context(line, state, max_context)
    state[:trailing_context] << line
    return unless state[:trailing_context].size > max_context

    state[:result].concat(state[:trailing_context].first(max_context))
    state[:trailing_context] = state[:trailing_context].last(max_context)
  end

  def add_leading_context(line, state, max_context)
    state[:leading_context] << line
    state[:leading_context].shift if state[:leading_context].size > max_context
  end

  def flush_context_buffers(state)
    state[:result].concat(state[:leading_context])
    state[:leading_context] = []
    state[:result].concat(state[:trailing_context])
    state[:trailing_context] = []
  end

  def finalize_hunk_context(state, max_context)
    unless state[:in_changes]
      state[:result].concat(state[:leading_context])
      return
    end
    return if state[:trailing_context].empty?

    state[:result].concat(state[:trailing_context].last(max_context))
  end
end
