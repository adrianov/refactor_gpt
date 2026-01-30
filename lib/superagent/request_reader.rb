# frozen_string_literal: true

require 'reline'

# Handles reading user requests from argv, stdin, or interactive input.
class RequestReader
  REQUEST_PROMPT = 'Enter request (press Enter twice to submit):'

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
      $stdin.read.strip
    end

  def read_interactive
    @display.puts REQUEST_PROMPT.cyan
    $stdout.puts ''

    read_interactive_silent
  end

  def read_interactive_silent
    lines = []
    saw_empty = false
    loop do
      line = read_interactive_line(lines)
      return nil if line.nil?
      break if line == :done
      if line == :empty_line
        return nil if saw_empty

        saw_empty = true
        next
      end

      saw_empty = false
      lines << line
    end
    result = lines.join("\n")
    result.to_s.strip.empty? ? nil : result
  end

  def read_interactive_line(lines)
    line = Reline.readline(lines.empty? ? '> ' : '  ', true)
    return nil if line.nil?

    line = line.to_s.strip
    return :done if line.empty? && !lines.empty?
    return :empty_line if line.empty?

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
      unless $stdin.tty?
        piped = read_from_stdin
        return piped if piped && !piped.to_s.strip.empty?
      end
      read_from_argv || read_interactive
    end

    def validate(req)
      return true if req && !req.to_s.strip.empty?

      exit 0
    end
  end
