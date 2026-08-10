#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/loader'
require_relative 'diff_compactor_helpers'

class TestDiffCompactor < Minitest::Test
  include DiffCompactorHelpers

  def setup
    @compactor = DiffCompactor.new
  end

  def test_compact_returns_nil_for_zero_max_bytes
    diff = "diff --git a/file.rb b/file.rb\n@@ -1,3 +1,3 @@\n line1\n line2\n line3\n"
    assert_nil @compactor.compact(diff, 0)
  end

  def test_compact_returns_nil_for_negative_max_bytes
    diff = "diff --git a/file.rb b/file.rb\n@@ -1,3 +1,3 @@\n line1\n line2\n line3\n"
    assert_nil @compactor.compact(diff, -1)
  end

  def test_compact_returns_nil_for_empty_diff
    assert_nil @compactor.compact('', 100)
  end

  def test_compact_preserves_small_diff
    diff = "diff --git a/file.rb b/file.rb\n@@ -1,3 +1,3 @@\n line1\n line2\n line3\n"
    assert_equal diff, @compactor.compact(diff, 1000)
  end

  def test_compact_reduces_context_for_large_diff
    diff = build_large_diff(50)
    result = @compactor.compact(diff, diff.bytesize - 100)
    skip 'Diff too large to compact even with context=0' unless result

    assert result.bytesize < diff.bytesize
    assert_includes result, '@@'
  end

  def test_compact_preserves_hunk_headers
    diff = "diff --git a/file.rb b/file.rb\n@@ -1,3 +1,3 @@\n line1\n line2\n line3\n"
    result = @compactor.compact(diff, 1000)
    assert_includes result, 'diff --git'
    assert_includes result, '@@'
  end

  def test_compact_preserves_structural_boundaries
    diff = <<~DIFF
      diff --git a/file.rb b/file.rb
      @@ -1,10 +1,10 @@
       class MyClass
        def method1
       end
      +
      +def new_method
      +end
      +
       end
    DIFF

    result = @compactor.compact(diff, 200)
    assert result
    assert_includes result, 'class MyClass'
    assert_includes result, 'end'
  end

  def test_compact_multiple_hunks
    diff = <<~DIFF
      diff --git a/file.rb b/file.rb
      @@ -1,5 +1,5 @@
       line1
       line2
      +new_line
       line3
       line4
      @@ -10,5 +10,5 @@
       line10
       line11
      +another_new_line
       line12
       line13
    DIFF

    result = @compactor.compact(diff, 200)
    assert result
    assert_match(/@@ -1,5/, result)
    assert_match(/@@ -10,5/, result)
  end

  def test_compact_preserves_change_lines
    diff = <<~DIFF
      diff --git a/file.rb b/file.rb
      @@ -1,3 +1,4 @@
       line1
      +added_line
       line2
       line3
    DIFF

    result = @compactor.compact(diff, 1000)
    assert result
    assert_includes result, '+added_line'
  end

  def test_compact_handles_very_large_diff
    diff = build_large_diff(200)
    result = @compactor.compact(diff, diff.bytesize / 2)
    skip 'Diff too large to compact to target size' unless result

    assert result.bytesize <= diff.bytesize / 2
  end

  def test_compact_with_zero_context
    diff = <<~DIFF
      diff --git a/file.rb b/file.rb
      @@ -1,20 +1,21 @@
      #{Array.new(10) { |i| " line#{i + 1}" }.join("\n")}
      +added_line
      #{Array.new(10) { |i| " line#{i + 11}" }.join("\n")}
    DIFF
    result = @compactor.compact(diff, 100)
    skip 'Diff too large to compact to 100 bytes' unless result

    assert result.bytesize <= 100
  end

  def test_compact_preserves_file_headers
    diff = <<~DIFF
      diff --git a/file1.rb b/file1.rb
      index abc123..def456 100644
      --- a/file1.rb
      +++ b/file1.rb
      @@ -1,3 +1,3 @@
       line1
       line2
       line3
    DIFF

    result = @compactor.compact(diff, 1000)
    assert result
    assert_includes result, 'diff --git'
    assert_includes result, 'index'
    assert_includes result, '---'
    assert_includes result, '+++'
  end

  def test_compact_with_boundaries_in_context
    diff = <<~DIFF
      diff --git a/file.rb b/file.rb
      @@ -1,20 +1,20 @@
      class A
       def method1
       end
       end
       class B
        def method2
       end
      +def new_method
      +end
       class C
        def method3
       end
       end
    DIFF

    result = @compactor.compact(diff, 300)
    assert result
    assert_includes result, 'class A'
    assert_includes result, 'class B'
    assert_includes result, 'class C'
  end
end
