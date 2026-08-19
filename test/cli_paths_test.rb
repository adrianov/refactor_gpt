# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/loader"

class TestCliPaths < Minitest::Test
  def test_partition_file_flags_and_hint
    rest, paths = CliPaths.partition(%w[--file lib/foo.rb --file=lib/bar.rb keep messages short])
    assert_equal %w[lib/foo.rb lib/bar.rb], paths
    assert_equal %w[keep messages short], rest
  end

  def test_partition_double_dash
    rest, paths = CliPaths.partition(%w[--auto -- deleted.rb other.rb])
    assert_equal %w[--auto], rest
    assert_equal %w[deleted.rb other.rb], paths
  end

  def test_select_supported_keeps_code_extensions
    kept = CliPaths.select_supported(%w[a.rb notes.bin], %w[.rb])
    assert_equal %w[a.rb], kept
  end
end
