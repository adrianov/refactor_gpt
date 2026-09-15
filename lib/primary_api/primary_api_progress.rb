# frozen_string_literal: true

require 'ruby-progressbar'

# Non-streaming requests give no byte feedback, so the bar advances at an estimated
# speed of prompt bytes per second. The speed self-calibrates from each request's
# duration (70% stored estimate, 30% measured) and persists across runs, keeping the
# bar's 100% near the real completion time.
module PrimaryApiProgress
  MIN_ESTIMATE_BYTES = 6000
  DEFAULT_PROGRESS_SPEED = 300.0
  PROGRESS_SPEED_FILE = File.join(Dir.home, '.refactor_gpt').freeze
  BAR_FORMAT = '%t: |%B| %p%% %e'.freeze
  TICK_SECONDS = 0.1

  # Bundles the bar with its ticker thread so finish can stop the thread before
  # completing the bar and recording the measured speed.
  EstimatedBar = Struct.new(:bar, :thread, :started_at, :total_size, :speed) do
    def finish
      thread&.kill
      thread&.join
      PrimaryApiProgress.stop_ticker(bar, started_at, total_size, speed)
    end
  end

  module_function

  def create(title:, estimate_bytes:)
    bar = ProgressBar.create(
      title: title.to_s,
      total: [estimate_bytes.to_i, MIN_ESTIMATE_BYTES].max,
      format: BAR_FORMAT,
      starting_at: 0,
      length: 100
    )
    handle = EstimatedBar.new(bar, nil, Process.clock_gettime(Process::CLOCK_MONOTONIC), bar.total, load_speed)
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

  def stop_ticker(bar, started_at, total_size, speed)
    bar.progress = bar.total
    bar.finish
    learn_speed(started_at, total_size, speed)
  rescue StandardError
    nil
  end

  def learn_speed(started_at, total_size, speed)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    return unless elapsed.positive?

    save_speed((speed * 0.7) + ((total_size / elapsed) * 0.3))
  end

  def speed_file
    PROGRESS_SPEED_FILE
  end

  def load_speed
    speed = File.exist?(speed_file) ? File.read(speed_file).to_f : DEFAULT_PROGRESS_SPEED
    speed.positive? ? speed : DEFAULT_PROGRESS_SPEED
  rescue SystemCallError
    DEFAULT_PROGRESS_SPEED
  end

  def save_speed(speed)
    File.write(speed_file, speed.round(2).to_s)
  rescue SystemCallError
    nil
  end
end
