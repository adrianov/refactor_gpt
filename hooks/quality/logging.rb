# frozen_string_literal: true

require 'fileutils'

module Quality
  # Writes resilient pipeline logs and records stage durations.
  module Logging
    def log_action(event, **fields)
      line = build_log_line(event, fields)
      file = File.join(LOGS, 'quality.log')
      FileUtils.mkdir_p(LOGS)
      rotate_oversized_log(file)
      File.open(file, 'a') { |f| f.puts line }
      STDERR.puts line
    rescue StandardError
      nil
    end

    def build_log_line(event, fields)
      "#{Time.now.strftime('%Y-%m-%d %H:%M:%S%z')} pid=#{Process.pid} session=#{@session_key} " \
        "#{event} #{fields.reject { |_, v| v.nil? || v.to_s.empty? }.map { |k, v| "#{k}=#{v}" }.join(' ')}".rstrip
    end

    def rotate_oversized_log(file)
      File.truncate(file, 0) if File.exist?(file) && File.size(file) > 5_000_000
    end

    def timed(stage)
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      log_action('done', stage: stage, ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round)
      result
    end
  end
end
