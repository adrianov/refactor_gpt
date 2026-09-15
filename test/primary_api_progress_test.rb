# frozen_string_literal: true

require 'oj'
require 'ruby-progressbar'
require 'stringio'
require 'tmpdir'
require 'minitest/autorun'
require_relative '../lib/loader'

# Tests PrimaryApiProgress: the estimated-speed bar advances on a timer, grows its
# total when the estimate is exceeded, and learns the measured speed per model slug
# so later bars track each model's real completion times independently.
class TestPrimaryApiProgress < Minitest::Test
  def with_speed_file(path)
    captured = []
    captured << PrimaryApiProgress.method(:speed_file)
    PrimaryApiProgress.define_singleton_method(:speed_file) { path }
    capture_io { yield }
  ensure
    PrimaryApiProgress.define_singleton_method(:speed_file, captured.pop) unless captured.empty?
  end

  def run_bar(model)
    handle = PrimaryApiProgress.create(title: 'Planning', estimate_bytes: 6000, model: model)
    sleep 0.2
    handle.finish
  end

  def test_bar_advances_by_estimated_speed
    Dir.mktmpdir do |dir|
      with_speed_file(File.join(dir, 'speed')) do
        handle = PrimaryApiProgress.create(title: 'Planning', estimate_bytes: 6000, model: 'glm-5.3')
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
        handle = PrimaryApiProgress.create(title: 'Planning', estimate_bytes: 6000, model: 'glm-5.3')
        sleep 0.3
        handle.finish
        assert handle.bar.finished?
        assert_operator Oj.load(File.read(path))['glm-5.3'], :>, 300.0
      end
    end
  end

  def test_speeds_are_learned_separately_per_model
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'speed')
      with_speed_file(path) do
        run_bar('glm-5.3')

        other = PrimaryApiProgress.create(title: 'Reviewing', estimate_bytes: 6000, model: 'openai/gpt-5.6-sol')
        assert_equal 300.0, other.speed
        other.finish

        speeds = Oj.load(File.read(path))
        assert_equal %w[glm-5.3 openai/gpt-5.6-sol], speeds.keys.sort
        assert_operator speeds['openai/gpt-5.6-sol'], :>, 300.0
      end
    end
  end

  def test_load_speed_uses_each_models_own_estimate
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'speed')
      File.write(path, Oj.dump('glm-5.3' => 900.0, 'openai/gpt-5.6-sol' => 120.0))
      with_speed_file(path) do
        assert_equal 900.0, PrimaryApiProgress.load_speed('glm-5.3')
        assert_equal 120.0, PrimaryApiProgress.load_speed('openai/gpt-5.6-sol')
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
        assert_equal 300.0, PrimaryApiProgress.load_speed('glm-5.3')
      end
    end
  end

  def test_load_speed_falls_back_to_default_for_legacy_bare_number_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'speed')
      File.write(path, '850.25')
      with_speed_file(path) do
        assert_equal 300.0, PrimaryApiProgress.load_speed('glm-5.3')
      end
    end
  end
end
