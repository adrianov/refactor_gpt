# frozen_string_literal: true

# Detects long-running build commands (cargo, make, etc.) among agent descendants; used to disable execution timeout.
module LongBuildDetector
  LONG_BUILD_COMMANDS = %w[cargo make].freeze

  module_function

  def long_build_running?(pid)
    return false unless pid

    descendants = ProcessDescendants.get_all_descendants(pid)
    descendants.any? { |d_pid| process_is_long_build?(d_pid) }
  end

  def process_is_long_build?(pid)
    cmdline = `ps -p #{pid} -o args= 2>/dev/null`.strip
    LONG_BUILD_COMMANDS.any? { |cmd| cmdline.match?(/\b#{Regexp.escape(cmd)}\b/) }
  end

  # Returns the first matching build command name (e.g. "cargo", "make") among agent descendants, or nil.
  def matched_build_name(pid)
    return nil unless pid

    descendants = ProcessDescendants.get_all_descendants(pid)
    LONG_BUILD_COMMANDS.find do |cmd|
      descendants.any? do |d_pid|
        cmdline = `ps -p #{d_pid} -o args= 2>/dev/null`.strip
        cmdline.match?(/\b#{Regexp.escape(cmd)}\b/)
      end
    end
  end
end
