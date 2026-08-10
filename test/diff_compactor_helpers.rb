# frozen_string_literal: true

# Shared fixtures and assertions for DiffCompactor tests.
module DiffCompactorHelpers
  def build_large_diff(context_lines)
    lines = ["diff --git a/file.rb b/file.rb", "@@ -1,#{context_lines} +1,#{context_lines} @@"]
    (1..context_lines).each { |i| lines << " line#{i}" }
    lines << '+added_line'
    (1..context_lines).each { |i| lines << " more_line#{i}" }
    "#{lines.join("\n")}\n"
  end

  def skip_marker_sample_diff
    <<~DIFF
      diff --git a/file.rb b/file.rb
      @@ -1,50 +1,51 @@
      #{Array.new(40) { |i| " line#{i + 1}" }.join("\n")}
      +added_line
      #{Array.new(9) { |i| " line#{i + 41}" }.join("\n")}
    DIFF
  end

  def assert_valid_skip_marker(count_str, start_str, end_str)
    count = count_str.to_i
    start_line = start_str.to_i
    end_line = end_str.to_i
    assert_predicate count, :positive?, 'Skip count should be positive'
    assert_predicate start_line, :positive?, 'Start line should be positive'
    assert_operator end_line, :>=, start_line, 'End line should be >= start line'
    assert_equal count, (end_line - start_line + 1), 'Count should match range'
  end
end
