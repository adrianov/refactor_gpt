# frozen_string_literal: true

require 'reline'

# Handles reading user requests from argv, stdin, or interactive input.
class RequestReader
    def initialize(display)
      @display = display
      @plan_mode = false
    end

  attr_reader :plan_mode

    def read_from_argv
      return nil if ARGV.empty?

      args = ARGV.dup
      if args.include?('--plan')
        @plan_mode = true
        args.delete('--plan')
      end
      args.delete('--print')
      args.join(' ') unless args.empty?
    end

    def read_from_stdin
      $stdin.read.strip unless $stdin.tty?
    end

    def read_interactive
      @display.puts 'Enter request:'.cyan
      @display.puts '(Press Enter twice, Ctrl+D, or Ctrl+C to submit/exit)'
      $stdout.puts ''

      read_interactive_silent
    end

    def read_interactive_silent
      lines = []
      loop do
        line = read_interactive_line(lines)
        return nil if line.nil?
        break if line == :done
        next if line == :continue

        lines << line
      end
      result = lines.join("\n")
      result.strip.empty? ? nil : result
    end

    def read_interactive_line(lines)
      line = Reline.readline(lines.empty? ? '> ' : '  ', true)
      return nil if line.nil?

      line = line.strip
      return :done if line.empty? && !lines.empty?
      return :continue if line.empty?

      line
    rescue Interrupt
      $stdout.puts ''
      @display.puts 'Interrupted. Exiting.'.yellow
      exit 0
    rescue StandardError => e
      @display.puts "Error reading input: #{e.message}".yellow
      return nil
    end

    def read
      read_from_argv || read_from_stdin || read_interactive
    end

    def validate(req)
      return true if req && !req.strip.empty?

      exit 0
    end
  end
