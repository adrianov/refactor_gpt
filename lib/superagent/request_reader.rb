# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'reline'
require_relative 'config_path'
require_relative '../signal_handler'
require_relative '../prompt_reader'

# Reline bug: whole_lines can contain nil when pasting; replace with ''. Pad result so modified_lines[i] is never nil.
module RelineNilSafeBuffer
  private

  def modify_lines(before, complete)
    before = before.to_a.map { |l| l.nil? ? '' : l.to_s }
    result = super(before, complete)
    n = before.size
    while result.size < n
      result << ''
    end
    result.first(n)
  end
end
Reline::LineEditor.prepend(RelineNilSafeBuffer)

# Handles reading user requests from argv, stdin, or interactive input. History is per-directory.
# Reline path used when running the agent (history, editing); chunked stdin when queue-only (large paste safe).
class RequestReader
  REQUEST_PROMPT = 'Enter request (press Enter twice to submit):'
  DISCARD_CMD = '/discard'
  PASTE_THRESHOLD = 0.2
  HISTORY_DIR = SuperagentConfig::CONFIG_DIR
  HISTORY_SEP = "\n---\n"
  MAX_HISTORY = 100
  READ_CHUNK = 4096

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

  def read_interactive(use_reline: true)
    @display.puts REQUEST_PROMPT.cyan
    $stdout.puts ''

    read_interactive_silent(use_reline: use_reline)
  end

  def load_request_history
    return unless Reline::HISTORY.empty?

    path = history_file_path
    return unless File.exist?(path)

    content = File.read(path)
    return if content.strip.empty?

    content.split(HISTORY_SEP).reverse_each { |req| Reline::HISTORY << req.strip unless req.strip.empty? }
  end

  # Regression: must persist to file so next run sees new requests; fsync ensures write is durable.
  def add_to_request_history(request)
    return if request.to_s.strip.empty?

    Reline::HISTORY << request
    path = history_file_path
    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, 'a') { |f| f.write(request + HISTORY_SEP); f.fsync }
    trim_history_file
  end

  def trim_history_file
    path = history_file_path
    return unless File.exist?(path)

    entries = File.read(path).split(HISTORY_SEP).reject(&:empty?)
    return if entries.size <= MAX_HISTORY

    File.write(path, entries.last(MAX_HISTORY).join(HISTORY_SEP) + HISTORY_SEP)
  end

  def read_interactive_silent(use_reline: true)
    if use_reline && $stdin.tty?
      try_paste_then_reline
    elsif use_reline
      collect_interactive_lines
    else
      read_until_double_newline
    end
  rescue Interrupt
    handle_interrupt(use_reline ? [] : [String.new])
  end

  # Bracketed paste: \e[200~...\e[201~. Route to Reline so we don't treat escapes as content.
  BRACKETED_PASTE_BYTES = "\e[200~".b.bytes.freeze

  # When stdin has data at entry: large chunk or "\n\n" → chunked read (avoids Reline hang on big paste).
  # Small chunk or bracketed paste → push back via pipe so Reline still sees it.
  def try_paste_then_reline
    return collect_interactive_lines unless IO.select([$stdin], nil, nil, 0)

    chunk = $stdin.readpartial(READ_CHUNK)
    return collect_with_stdin_pushback(chunk) if chunk.bytesize >= 6 && chunk.bytes.first(6) == BRACKETED_PASTE_BYTES
    return read_paste_with_initial(chunk) if chunk.bytesize >= READ_CHUNK || chunk.include?("\n\n")

    collect_with_stdin_pushback(chunk)
  end

  def collect_with_stdin_pushback(chunk)
    r, w = IO.pipe
    w.write(chunk)
    stdin_orig = $stdin
    stop_r, stop_w = IO.pipe
    copy_thread = spawn_stdin_copy_thread(stdin_orig, w, stop_r)
    $stdin = r
    collect_interactive_lines
  ensure
    $stdin = stdin_orig if stdin_orig
    stop_w&.close
    w&.close
    copy_thread&.join(2)
    stop_r&.close
    r&.close
  end

  def read_paste_with_initial(chunk)
    buffer = chunk.dup
    until buffer.include?("\n\n")
      buffer << $stdin.readpartial(READ_CHUNK)
    end
    request_from_buffer(buffer)
  rescue EOFError
    request_from_buffer(buffer.to_s)
  rescue Interrupt
    handle_interrupt([buffer])
  end

  def collect_interactive_lines
    load_request_history
    set_reline_placeholder_proc
    set_reline_filename_completion
    lines = []
    saw_empty = false
    last_time = Time.now
    loop do
      action, saw_empty, last_time, line = process_one_line(lines, saw_empty, last_time)
      return nil if action == :return_nil
      break if action == :break
      next if action == :next

      lines << line
    end
    (r = lines.map(&:to_s).join("\n")).to_s.strip.empty? ? nil : r
  rescue Interrupt
    handle_interrupt(lines)
  ensure
    Reline.output_modifier_proc = nil
    Reline.completion_proc = nil
  end

  def process_one_line(lines, saw_empty, last_time)
    line, new_last_time, elapsed = read_line_with_elapsed(lines, last_time)
    return [:return_nil, saw_empty, new_last_time, nil] if line.nil?
    return handle_empty_line(line, elapsed, saw_empty, lines) if empty_line_token?(line)

    [:append, false, new_last_time, line]
  end

  def handle_empty_line(line, elapsed, saw_empty, lines)
    flow, new_saw_empty = apply_empty_line(line, elapsed, saw_empty, lines)
    action = flow == :return_nil ? :return_nil : (flow == :break ? :break : :next)
    lines << '' if flow == :continue
    [action, new_saw_empty, Time.now, nil]
  end

  def set_reline_placeholder_proc
    Reline.output_modifier_proc = proc do |str, **|
      (str || '').to_s
    end
  end

  def set_reline_filename_completion
    Reline.completion_proc = proc do |word|
      next [] if word.nil?
      dir = Dir.pwd
      entries = Dir.entries(dir).reject { |e| e == '.' || e == '..' }
      prefix = word.to_s
      entries.select { |e| e.start_with?(prefix) }.sort
    end
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

  def read_interactive_line(lines)
    prompt = (PromptReader.multiline_prompt(lines.empty?) || '').to_s
    line = Reline.readline(prompt.empty? ? ' ' : prompt, true)
    return nil if line.nil?

    line = line.to_s.strip
    return :done if line.empty? && !lines.empty?
    return :empty_line if line.empty?

    line
  rescue StandardError => e
    @display.puts "Error reading input: #{(e.message || e.class.name)}".yellow
    nil
  end

  def read_until_double_newline
    buffer = String.new
    loop do
      buffer << $stdin.readpartial(READ_CHUNK)
      break if buffer.include?("\n\n")
    end
    request_from_buffer(buffer)
  rescue EOFError
    request_from_buffer(buffer.to_s)
  rescue Interrupt
    handle_interrupt([buffer])
  end

  def request_from_buffer(buffer)
    request = buffer.split("\n\n", 2).first.to_s.rstrip
    request.empty? ? nil : request
  end

  def handle_interrupt(lines)
    $stdout.puts ''
    partial = lines.map(&:to_s).join("\n").strip
    if partial.empty?
      @display.puts 'Interrupted. No request entered. Exiting.'.yellow
    else
      @display.puts 'Interrupted. Request so far:'.yellow
      @display.puts partial
    end
    exit SignalHandler::EXIT_SIGINT
  end

  def read(use_reline: true)
    unless $stdin.tty?
      piped = read_from_stdin
      return piped if piped && !piped.to_s.strip.empty?
    end
    read_from_argv || read_interactive(use_reline: use_reline)
  end

  def self.discard_command?(str)
    str.to_s.strip == DISCARD_CMD
  end

  def validate(req)
    return true if req && !req.to_s.strip.empty?

    exit 0
  end

  private

  def spawn_stdin_copy_thread(stdin_orig, w, stop_r)
    Thread.new do
      loop do
        ready = IO.select([stdin_orig, stop_r], nil, nil, 0.2)
        break if ready && ready[0].include?(stop_r)
        next unless ready && ready[0].include?(stdin_orig)

        w.write(stdin_orig.readpartial(READ_CHUNK))
      end
    rescue IOError, Errno::EPIPE
      # Pipe closed or broken
    end
  end

  def history_file_path
    cwd_hash = Digest::SHA256.hexdigest(Dir.pwd)
    File.join(HISTORY_DIR, "#{cwd_hash}_history")
  end
end
