# frozen_string_literal: true

# Orchestrates context reduction across unified-diff hunks.
class DiffCompactor
  include DiffCompactorHunks
  include DiffCompactorMarkers

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

      return result if result.join.bytesize <= max_bytes
    end

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

  def diff_header_line?(line)
    line.start_with?("diff --git") || line.start_with?("index ") || line.start_with?("---") ||
      line.start_with?("+++") || hunk_start?(line)
  end

  def hunk_start?(line)
    line.start_with?("@@")
  end
end
