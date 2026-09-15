# frozen_string_literal: true

require 'ruby-progressbar'
require 'stringio'
require 'tmpdir'
require 'minitest/autorun'
require_relative '../lib/loader'

# Tests PrimaryApiProgress: the estimated-speed bar advances on a timer, grows its
# total when the estimate is exceeded, and learns the measured speed into the speed
# file so later bars track real completion times.
class TestPrimaryApiProgress < Minitest::Test
  def with_speed_file(path)
    captured = []
    captured << PrimaryApiProgress.method(:speed_file)
    PrimaryApiProgress.define_singleton_method(:speed_file) { path }
    capture_io { yield }
  ensure
    PrimaryApiProgress.define_singleton_method(:speed_file, captured.pop) unless captured.empty?
  end

  def test_bar_advances_by_estimated_speed
    Dir.mktmpdir do |dir|
      with_speed_file(File.join(dir, 'speed')) do
        handle = PrimaryApiProgress.create(title: 'Planning', estimate_bytes: 6000)
        sleep 0.35
        assert_operator handle.bar.progress, :>=, 30
        handle.finish
      end
    end
  end

  def test_finish_completes_bar_and_learns_measured_speed
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'speed')
      with_speed_file(path) do
        handle = PrimaryApiProgress.create(title: 'Planning', estimate_bytes: 6000)
        sleep 0.3
        handle.finish
        assert handle.bar.finished?
        assert_operator File.read(path).to_f, :>, 300.0
      end
    end
  end

  def test_adjust_total_grows_estimate_when_progress_exceeds_it
    bar = ProgressBar.create(total: 100, output: StringIO.new, length: 100)
    PrimaryApiProgress.adjust_total(bar, 250, 100)
    assert_equal 251, bar.total
    PrimaryApiProgress.adjust_total(bar, 300, 100)
    assert_equal 351, bar.total
  end

  def test_load_speed_falls_back_to_default_for_invalid_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'speed')
      File.write(path, 'not-a-number')
      with_speed_file(path) do
        assert_equal 300.0, PrimaryApiProgress.load_speed
      end
    end
  end
end
