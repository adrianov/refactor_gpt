# frozen_string_literal: true

# Shared progress-bar helpers for primary API clients (OpenAI-compatible and Gemini).
# Host must define PROGRESS_SPEED_FILE, DEFAULT_PROGRESS_SPEED, and initialize
# @progress_mutex / @progress_stop / @progress_title.
module PrimaryApiProgress
  def setup_progress_tracking(messages, json: false, title: nil)
    total_size = [messages.to_s.bytesize, 6000].max
    progress_speed = load_progress_speed

    progressbar = create_progress_bar(total_size, title)
    start_time = Time.now

    set_progress_stop(false)
    progress_thread = start_progress_thread(progressbar, start_time, progress_speed, total_size)

    begin
      make_request_with_debug(messages, json: json)
    ensure
      finish_progress(progress_thread, progressbar, start_time, total_size)
    end
  end

  def load_progress_speed
    return @progress_speed if defined?(@progress_speed)

    @progress_speed =
      File.exist?(PROGRESS_SPEED_FILE) ? File.read(PROGRESS_SPEED_FILE).to_f : DEFAULT_PROGRESS_SPEED
    @progress_speed = DEFAULT_PROGRESS_SPEED if @progress_speed <= 0
    @progress_speed
  rescue SystemCallError, ArgumentError
    @progress_speed = DEFAULT_PROGRESS_SPEED
  end

  def save_progress_speed(speed)
    File.write(PROGRESS_SPEED_FILE, speed.round(2).to_s)
  rescue SystemCallError
    # ignore persistence errors
  end

  def create_progress_bar(total_size, title)
    ProgressBar.create(
      title: title || @progress_title,
      total: total_size,
      format: "%t: |%B| %p%% %e",
      length: 100
    )
  end

  def start_progress_thread(progressbar, start_time, progress_speed, total_size)
    Thread.new do
      run_progress_loop(progressbar, start_time, progress_speed, total_size)
    end
  end

  def run_progress_loop(progressbar, start_time, progress_speed, total_size)
    loop do
      break if progress_stopped?
      break unless update_progress_safely(progressbar, start_time, progress_speed, total_size)

      sleep 0.1
    end
  end

  def set_progress_stop(value)
    @progress_mutex.synchronize { @progress_stop = value }
  end

  def progress_stopped?
    @progress_mutex.synchronize { @progress_stop }
  end

  def update_progress_safely(progressbar, start_time, progress_speed, total_size)
    return false if progressbar.finished?

    elapsed_time = Time.now - start_time
    progress = (elapsed_time * progress_speed).round

    # Extend total when needed so percentage can count backwards then forward again
    adjust_progressbar_total(progressbar, progress, total_size)
    progressbar.progress = progress
    true
  rescue ProgressBar::InvalidProgressError
    # ProgressBar::InvalidProgressError: progress set after finish or invalid value
    warn "Progress update stopped due to progressbar state" if @debug
    false
  end

  def adjust_progressbar_total(progressbar, progress, total_size)
    return unless progress >= progressbar.total

    # Backwards counting: extend total so the displayed percentage drops (counts
    # backwards from 100%), then progress continues forward again. Avoids holding
    # at 100% when we don't know real response size and gives continuous feedback.
    progressbar.total += total_size
    # Rare case: when progress far exceeds total, adding initial size isn't enough
    progressbar.total = progress + 1 if progressbar.total <= progress
  end

  def finish_progress(progress_thread, progressbar, start_time, total_size)
    return unless progress_thread && progressbar

    set_progress_stop(true)
    # Give the thread a moment to exit cleanly before forcing termination
    progress_thread.join(0.5)
    progress_thread.kill if progress_thread.alive?

    finish_progressbar_safely(progressbar)
    save_progress_speed_from_elapsed(start_time, total_size)
  end

  def finish_progressbar_safely(progressbar)
    return if progressbar.finished?

    progressbar.progress = progressbar.total
    progressbar.finish
  rescue ProgressBar::InvalidProgressError
    # Progressbar already finished or in invalid state
  end

  def save_progress_speed_from_elapsed(start_time, total_size)
    elapsed_time = Time.now - start_time
    return unless elapsed_time.positive?

    # Use actual content size instead of inflated progressbar.progress
    # progressbar.progress may be inflated to provide continuous visual feedback
    actual_speed = total_size / elapsed_time
    save_progress_speed((load_progress_speed * 0.7) + (actual_speed * 0.3))
  end
end
