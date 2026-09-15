# frozen_string_literal: true

require 'oj'
require 'ruby-progressbar'

# Non-streaming requests give no byte feedback, so the bar advances at an estimated
# speed of prompt bytes per second. Generation speed differs per model, so each model
# slug keeps its own calibrated speed: every request blends the stored estimate with
# its measured pace (70% stored, 30% measured) and persists the result, keeping the
# bar's 100% near the real completion time for whichever model runs.
module PrimaryApiProgress
  MIN_ESTIMATE_BYTES = 6000
  DEFAULT_PROGRESS_SPEED = 300.0
  PROGRESS_SPEED_FILE = File.join(Dir.home, '.refactor_gpt').freeze
  BAR_FORMAT = '%t: |%B| %p%% %e'.freeze
  TICK_SECONDS = 0.1

  # Bundles the bar with its ticker thread so finish can stop the thread before
  # completing the bar and recording the measured speed for this model.
  EstimatedBar = Struct.new(:bar, :thread, :started_at, :total_size, :model, :speed) do
    def finish
      thread&.kill
      thread&.join
      PrimaryApiProgress.stop_ticker(bar, started_at, total_size, model, speed)
    end
  end

  module_function

  def create(title:, estimate_bytes:, model:)
    bar = ProgressBar.create(
      title: title.to_s,
      total: [estimate_bytes.to_i, MIN_ESTIMATE_BYTES].max,
      format: BAR_FORMAT,
      starting_at: 0,
      length: 100
    )
    handle = EstimatedBar.new(
      bar, nil, Process.clock_gettime(Process::CLOCK_MONOTONIC), bar.total, model, load_speed(model)
    )
    handle.thread = Thread.new { run_ticker(handle) }
    handle
  end

  def run_ticker(handle)
    loop do
      sleep TICK_SECONDS
      progress = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - handle.started_at) * handle.speed).round
      adjust_total(handle.bar, progress, handle.total_size)
      handle.bar.progress = progress
    end
  rescue StandardError
    nil
  end

  # Lets the bar keep moving past 100% by growing the total once the estimate is
  # exhausted, instead of parking at 100% while the request is still running.
  def adjust_total(bar, progress, total_size)
    return if progress < bar.total

    bar.total += total_size
    bar.total = progress + 1 if bar.total <= progress
  end

  def stop_ticker(bar, started_at, total_size, model, speed)
    bar.progress = bar.total
    bar.finish
    learn_speed(started_at, total_size, model, speed)
  rescue StandardError
    nil
  end

  def learn_speed(started_at, total_size, model, speed)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    return unless elapsed.positive?

    save_speed(model, (speed * 0.7) + ((total_size / elapsed) * 0.3))
  end

  def speed_file
    PROGRESS_SPEED_FILE
  end

  def load_speed(model)
    speed = read_speeds.fetch(model, DEFAULT_PROGRESS_SPEED)
    speed.positive? ? speed : DEFAULT_PROGRESS_SPEED
  end

  def save_speed(model, speed)
    speeds = read_speeds
    speeds[model] = speed.round(2)
    File.write(speed_file, Oj.dump(speeds))
  rescue SystemCallError
    nil
  end

  # Reads the persisted {model slug => speed} map; unreadable or non-map content
  # (including the legacy bare-number format) starts every model from the default.
  def read_speeds
    parsed = Oj.load(File.exist?(speed_file) ? File.read(speed_file) : '')
    parsed.is_a?(Hash) ? parsed.select { |_, speed| speed.is_a?(Numeric) } : {}
  rescue SystemCallError, Oj::ParseError
    {}
  end
end
