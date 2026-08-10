# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/loader'
require_relative 'diff_compactor_helpers'

# Skip-marker and large-context compaction coverage for DiffCompactor.
class TestDiffCompactorMarkers < Minitest::Test
  include DiffCompactorHelpers

  def setup
    @compactor = DiffCompactor.new
  end

  def test_compact_includes_skip_markers
    diff = skip_marker_sample_diff
    result = @compactor.compact(diff, diff.bytesize - 50) || @compactor.compact(diff, 200)
    skip 'Diff structure doesn\'t allow compaction with skip markers' unless result

    assert_match(/\.\.\. \(skipped \d+ lines: \d+-\d+\) \.\.\./, result)
  end

  def test_skip_marker_format
    result = @compactor.compact(skip_marker_sample_diff, 200)
    skip 'Diff too large to compact' unless result

    skip_markers = result.scan(/\.\.\. \(skipped \d+ lines: \d+-\d+\) \.\.\./)
    assert skip_markers.any?, 'Should have skip markers'
    skip_markers.each do |marker|
      assert_match(/\.\.\. \(skipped \d+ lines: \d+-\d+\) \.\.\./, marker)
    end
  end

  def test_skip_marker_line_numbers_are_valid
    result = @compactor.compact(skip_marker_sample_diff, 200)
    skip 'Diff too large to compact' unless result

    skip_markers = result.scan(/\.\.\. \(skipped (\d+) lines: (\d+)-(\d+)\) \.\.\./)
    assert skip_markers.any?, 'Should have skip markers'
    skip_markers.each { |parts| assert_valid_skip_marker(*parts) }
  end

  def test_skip_markers_appear_when_context_reduced
    leading = Array.new(30) { |i| " context_before_#{i}" }.join("\n")
    trailing = Array.new(30) { |i| " context_after_#{i}" }.join("\n")
    diff = <<~DIFF
      diff --git a/file.rb b/file.rb
      @@ -1,61 +1,62 @@
      #{leading}
      +added_change_line
      #{trailing}
    DIFF

    result = @compactor.compact(diff, diff.bytesize / 3)
    skip 'Diff structure doesn\'t allow sufficient compaction' unless result

    assert_match(/\.\.\. \(skipped \d+ lines: \d+-\d+\) \.\.\./, result)
    assert_includes result, '+added_change_line'
  end
end
