# frozen_string_literal: true

require_relative '../signal_handler'
require_relative '../prompt_reader'
require 'reline'

# Handles reading user requests from argv, stdin, or interactive input.
class RequestReader
  REQUEST_PROMPT = 'Enter request (press Enter twice to submit):'
  PASTE_THRESHOLD = 0.2

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
    lines = collect_interactive_lines
    return nil if lines.nil?

    result = lines.join("\n")
    result.to_s.strip.empty? ? nil : result
  end

  def collect_interactive_lines
    lines = []
    saw_empty = false
    last_time = Time.now
    loop do
      line, last_time, elapsed = read_line_with_elapsed(lines, last_time)
      return nil if line.nil?
      if empty_line_token?(line)
        flow, saw_empty = apply_empty_line(line, elapsed, saw_empty, lines)
        return nil if flow == :return_nil
        break if flow == :break
        next
      end

      saw_empty = false
      lines << line
    end
    lines
  rescue Interrupt
    handle_interrupt(lines)
  end

  def empty_line_token?(line)
    line == :done || line == :empty_line
  end

  def read_line_with_elapsed(lines, last_time)
    line = read_interactive_line(lines)
    now = Time.now
    [line, now, now - last_time]
  end

  def apply_empty_line(line, elapsed, saw_empty, lines)
    if elapsed < PASTE_THRESHOLD
      lines << ''
      return [:continue, saw_empty]
    end
    return [:break, saw_empty] if line == :done
    return [:return_nil, saw_empty] if line == :empty_line && saw_empty

    [:continue, true]
  end

  def handle_interrupt(lines)
    $stdout.puts ''
    partial = lines.join("\n").strip
    if partial.empty?
      @display.puts 'Interrupted. No request entered. Exiting.'.yellow
    else
      @display.puts 'Interrupted. Request so far:'.yellow
      @display.puts partial
    end
    exit SignalHandler::EXIT_SIGINT
  end

  def read_interactive_line(lines)
    line = Reline.readline(PromptReader.multiline_prompt(lines.empty?), true)
    return nil if line.nil?

    line = line.to_s.strip
    return :done if line.empty? && !lines.empty?
    return :empty_line if line.empty?

    line
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
