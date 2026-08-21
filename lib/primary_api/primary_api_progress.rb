# frozen_string_literal: true

require 'ruby-progressbar'

# Stream-driven progress bar: advances with actually-received response bytes instead of a
# simulated speed estimate, growing the total when reality outgrows the input-size guess.
module PrimaryApiProgress
  MIN_ESTIMATE_BYTES = 6000

  module_function

  def create(title:, estimate_bytes:)
    ProgressBar.create(
      title: title.to_s,
      total: [estimate_bytes.to_i, MIN_ESTIMATE_BYTES].max,
      starting_at: 0,
      length: 100
    )
  end

  def record(bar, received_bytes)
    grow_total(bar, received_bytes)
    bar.progress = received_bytes
  end

  def finish(bar)
    bar.finish
  rescue StandardError
    nil
  end

  def grow_total(bar, received_bytes)
    bar.total = received_bytes * 2 if received_bytes > bar.total
  end
end
