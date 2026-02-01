# frozen_string_literal: true

require 'rbconfig'

# Detects whether a test runner (rspec, minitest, etc.) is running; used to disable execution timeout.
module TestRunnerDetector
  TEST_RUNNERS = %w[rspec minitest test-unit cucumber jest mocha pytest].freeze

  module_function

  def test_runner_running?(pid = nil)
    return false unless RbConfig::CONFIG['host_os'] =~ /linux|darwin|bsd/

    TEST_RUNNERS.any? do |runner|
      if pid
        descendants = ProcessDescendants.get_all_descendants(pid)
        descendants.any? { |d_pid| process_matches_runner?(d_pid, runner) }
      else
        system_runner_running?(runner)
      end
    end
  end

  def system_runner_running?(runner)
    return true if system("pgrep -x #{runner} > #{File::NULL} 2>&1")

    output = `ps ax -o comm,args 2>/dev/null`
    return false if output.empty?

    output.each_line.any? { |line| line_matches_runner?(line, runner) }
  end

  def line_matches_runner?(line, runner)
    return false if line.to_s.strip.empty?

    comm, args = line.split(nil, 2)
    return false if args.nil? || !%w[ruby node python].include?(comm)
    return false unless args.match?(/\b(?:bundle\s+exec\s+)?#{runner}(?:\s|$)/)

    !args.match?(/\b(?:grep|find|vim|nano|emacs|less|more|cat|head|tail|ag|rg)\s/)
  end

  def process_matches_runner?(pid, runner)
    cmdline = `ps -p #{pid} -o args= 2>/dev/null`.to_s.strip
    cmdline.include?(runner)
  end
end
