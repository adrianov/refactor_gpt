# frozen_string_literal: true

require 'fileutils'
require 'reline'

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
  REQUEST_PROMPT = 'Enter request (press Enter twice to submit; empty to exit):'
  SHELL_CMD_PREFIX = '! '
  DISCARD_CMD = '/discard'
  RESET_CMD = '/reset'
  PASTE_THRESHOLD = 0.2
  HISTORY_DIR = ConfigPath::CONFIG_DIR
  HISTORY_SEP = "\n---\n"
  MAX_HISTORY = 100
  MAX_HISTORY_LINES = 25
  READ_CHUNK = 4096

  def initialize(display)
    @display = display
    @plan_mode = false
    # Freeze path at startup so history is always for the directory from which superagent was started.
    @history_file_path = File.join(HISTORY_DIR, "#{ConfigPath.project_id}_history")
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
    RequestPreparer.normalized_request_text($stdin.read)
  end

  def read_interactive(use_reline: true)
    read_request(use_reline: use_reline)
  end

  # Single entry point for getting a request from the user (with or without output collection).
  # skip_prompt: when true, caller has already shown the prompt (e.g. when output is paused and buffered).
  def read_request(use_reline: true, skip_prompt: false)
    print_request_prompt unless skip_prompt
    read_until_non_shell(use_reline: use_reline, for_queue: false)
  end

  # Reads until the user enters a non-shell request. Used when caller has already shown the prompt (e.g. queue).
  def read_until_non_shell(use_reline: true, for_queue: false)
    loop do
      raw = read_interactive_silent(use_reline: use_reline, for_queue: for_queue)
      return raw unless shell_command?(raw)

      run_shell_cmd(raw)
      print_request_prompt
    end
  end

  def print_request_prompt
    $stdout.puts "\n#{REQUEST_PROMPT}\n\n"
    $stdout.flush
  end

  # Load once per process when history is empty; avoids re-reading file on every queue prompt (Reline slowness).
  def load_request_history
    return unless Reline::HISTORY.empty?

    entries = read_history_entries_from_file
    return if entries.empty?

    history_entries_in_reline_order(entries).each do |s|
      Reline::HISTORY << s if history_entry_ok?(s)
    end
  end

  # Regression: must persist to file so next run sees new requests; fsync ensures write is durable.
  def add_to_request_history(request)
    return if request.nil? || request.to_s.strip.empty?
    return unless history_entry_ok?(request)
    norm_last = RequestPreparer.normalized_request_text(Reline::HISTORY.last)
    return if Reline::HISTORY.any? && norm_last == RequestPreparer.normalized_request_text(request)

    Reline::HISTORY << request
    append_request_to_history_file(request)
    trim_history_file
  end

  def trim_history_file
    return unless File.exist?(@history_file_path)

    entries = File.read(@history_file_path).split(HISTORY_SEP).reject(&:empty?)
    return if entries.size <= MAX_HISTORY

    File.write(@history_file_path, entries.last(MAX_HISTORY).join(HISTORY_SEP) + HISTORY_SEP)
  end

  def read_interactive_silent(use_reline: true, for_queue: false)
    if use_reline && $stdin.tty?
      try_paste_then_reline(for_queue)
    elsif use_reline
      collect_interactive_lines(for_queue)
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
  def try_paste_then_reline(for_queue = false)
    return collect_interactive_lines(for_queue) unless IO.select([$stdin], nil, nil, 0)

    chunk = $stdin.readpartial(READ_CHUNK)
    bracketed = chunk.bytesize >= 6 && chunk.bytes.first(6) == BRACKETED_PASTE_BYTES
    return collect_with_stdin_pushback(chunk, for_queue) if bracketed
    return read_paste_with_initial(chunk) if chunk.bytesize >= READ_CHUNK || chunk.include?("\n\n")

    collect_with_stdin_pushback(chunk, for_queue)
  end

  def collect_with_stdin_pushback(chunk, for_queue = false)
    r, w = IO.pipe
    w.write(chunk)
    stdin_orig = $stdin
    stop_r, stop_w = IO.pipe
    copy_thread = spawn_stdin_copy_thread(stdin_orig, w, stop_r)
    $stdin = r
    collect_interactive_lines(for_queue)
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

  def collect_interactive_lines(for_queue = false)
    load_request_history unless for_queue
    set_reline_placeholder_proc
    set_reline_filename_completion
    lines = []
    saw_empty = false
    last_time = Time.now
    loop do
      action, saw_empty, last_time, line = process_one_line(lines, saw_empty, last_time, for_queue)
      return nil if action == :return_nil
      break if action == :break
      next if action == :next

      lines << line
    end
    lines_to_result(lines)
  rescue Interrupt
    handle_interrupt(lines)
  ensure
    Reline.output_modifier_proc = nil
    Reline.completion_proc = nil
  end

  def lines_to_result(lines)
    r = RequestPreparer.normalized_request_text(lines.map(&:to_s).join("\n"))
    r.empty? ? nil : r
  end

  def process_one_line(lines, saw_empty, last_time, for_queue = false)
    line, new_last_time, elapsed = read_line_with_elapsed(lines, last_time)
    return [:return_nil, saw_empty, new_last_time, nil] if line.nil?
    return handle_empty_line(line, elapsed, saw_empty, lines, for_queue) if empty_line_token?(line)

    [:append, false, new_last_time, line]
  end

  def handle_empty_line(line, elapsed, saw_empty, lines, for_queue = false)
    flow, new_saw_empty = apply_empty_line(line, elapsed, saw_empty, lines, for_queue)
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

  def apply_empty_line(line, elapsed, saw_empty, lines, for_queue = false)
    if elapsed < PASTE_THRESHOLD
      lines << ''
      return [:continue, saw_empty]
    end
    return [:break, saw_empty] if line == :done
    return [:break, saw_empty] if for_queue && line == :empty_line && lines.empty?
    return [:return_nil, saw_empty] if line == :empty_line && saw_empty

    [:continue, true]
  end

  def read_interactive_line(lines)
    prompt = (PromptReader.multiline_prompt(lines.empty?) || '').to_s
    line = Reline.readline(prompt.empty? ? ' ' : prompt, true)
    parse_line_result(line, lines)
  rescue StandardError => e
    @display.puts "Error reading input: #{(e.message || e.class.name)}".yellow
    nil
  end

  def parse_line_result(line, lines)
    return nil if line.nil?

    stripped = line.to_s.strip
    return :done if stripped.empty? && !lines.empty?
    return :empty_line if stripped.empty?

    stripped
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
    partial = lines.map(&:to_s).join("\n")
    if partial.nil? || partial.to_s.strip.empty?
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
    result = read_from_argv || read_interactive(use_reline: use_reline)
    if shell_command?(result)
      run_shell_cmd(result)
      return read_interactive(use_reline: use_reline)
    end
    result
  end

  def self.discard_command?(str)
    RequestPreparer.normalized_request_text(str) == DISCARD_CMD
  end

  def self.reset_command?(str)
    RequestPreparer.normalized_request_text(str) == RESET_CMD
  end

  def validate(req)
    return true if req && !req.to_s.strip.empty?

    exit 0
  end

  private

  def shell_command?(raw)
    raw.to_s.strip.start_with?(SHELL_CMD_PREFIX)
  end

  def run_shell_cmd(raw)
    cmd = raw.to_s.strip.delete_prefix(SHELL_CMD_PREFIX)
    system(cmd) unless cmd.empty?
  end

  # Returns normalized, non-empty entries in file order (oldest first).
  def read_history_entries_from_file
    return [] unless File.exist?(@history_file_path)

    content = File.read(@history_file_path)
    return [] if content.nil? || content.to_s.strip.empty?

    content.split(HISTORY_SEP).filter_map do |req|
      s = RequestPreparer.normalized_request_text(req)
      s if s && !s.empty?
    end
  end

  def history_entries_in_reline_order(entries)
    # Reline expects chronological order (oldest first); Up then shows newest first. Do not reverse.
    entries
  end

  def history_entry_ok?(text)
    text.to_s.lines.size <= MAX_HISTORY_LINES
  end

  def append_request_to_history_file(request)
    FileUtils.mkdir_p(File.dirname(@history_file_path))
    File.open(@history_file_path, 'a') { |f| f.write(request + HISTORY_SEP); f.fsync }
  end

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

end
