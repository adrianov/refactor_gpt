# frozen_string_literal: true

# One-shot sandboxed Q&A mode for superagent (`superagent ask`): stdin/argv prompts,
# interactive queue loop, and OpenRouter-backed answers.
module AskModeRunner
  module_function

  def ask_mode_classification?(title)
    ['Classifying to a session', 'Classifying request'].include?(title.to_s.strip)
  end

  def run_ask_mode(show_full_prompt: false)
    sandbox = "/tmp/sandbox_#{Random.hex(8)}"
    FileUtils.mkdir_p(sandbox)
    original_cwd = Dir.pwd
    Dir.chdir(sandbox)
    begin
      if $stdin.tty?
        run_ask_mode_interactive(show_full_prompt: show_full_prompt)
      else
        run_ask_mode_once(show_full_prompt: show_full_prompt)
      end
    ensure
      Dir.chdir(original_cwd)
      FileUtils.rm_rf(sandbox)
    end
  end

  def run_ask_mode_once(show_full_prompt: false)
    prompt, title = resolve_ask_prompt
    classification = ask_mode_classification?(title)
    client = ask_mode_client
    invoke_ask_client(client, prompt, classification ? nil : title, show_full_prompt: show_full_prompt)
    exit 0
  end

  def run_ask_mode_interactive(show_full_prompt: false)
    display = Display.new
    request_reader = RequestReader.new(display)
    prompt, title = resolve_ask_prompt_interactive(request_reader)
    exit 0 if prompt.to_s.strip.empty?

    queue, worker = start_ask_worker(prompt, title, show_full_prompt)
    run_ask_main_input_loop(queue, request_reader, display)
    queue << :quit
    worker.join
    exit 0
  end

  def start_ask_worker(prompt, title, show_full_prompt)
    client = ask_mode_client
    queue = Queue.new
    queue << { prompt: prompt, title: title }
    worker = Thread.new { ask_worker_loop(queue, client, show_full_prompt) }
    [queue, worker]
  end

  def resolve_ask_prompt_interactive(request_reader)
    if ARGV.any?
      [ARGV.join(' ').strip, nil]
    else
      raw = request_reader.read_request
      [RequestPreparer.normalized_request_text(raw).to_s.strip, nil]
    end
  end

  def ask_worker_loop(queue, client, show_full_prompt)
    loop do
      item = queue.pop
      break if item == :quit

      classification = ask_mode_classification?(item[:title])
      invoke_ask_client(client, item[:prompt], classification ? nil : item[:title],
                       show_full_prompt: show_full_prompt)
    end
  end

  def run_ask_main_input_loop(queue, request_reader, display)
    input_io = File.open("/dev/tty", "r")
    loop do
      break unless ask_input_ready?(input_io)

      $stdout.puts "\n#{RequestReader::REQUEST_PROMPT}\n\n"
      $stdout.flush
      raw = request_reader.read_until_non_shell(use_reline: true, for_queue: true)
      break if ask_handle_queue_input(queue, request_reader, display, raw) == :quit
    end
  rescue IOError, Errno::EIO
    # Terminal closed or unavailable
  ensure
    input_io&.close
  end

  def ask_input_ready?(input_io)
    ready = IO.select([input_io], nil, nil, 0.3)
    return false unless ready

    line = input_io.gets
    return false if line.nil?

    line.chomp.empty?
  end

  def ask_handle_queue_input(queue, request_reader, display, raw)
    if RequestReader.discard_command?(raw)
      display.puts "Queued requests discarded.".yellow
      return :next
    end
    return :quit if raw.to_s.strip == "/quit"
    return :quit if raw.nil? || raw.to_s.strip.empty?

    text = RequestPreparer.normalized_request_text(raw)
    request_reader.add_to_request_history(raw)
    queue << { prompt: text, title: nil }
    display.puts "Queued: #{RequestHistoryFormatter.queue_preview(text)}".light_blue
    :next
  end

  def invoke_ask_client(client, prompt, title, show_full_prompt: false)
    messages = ask_mode_messages(prompt)
    if show_full_prompt
      full_text = messages.map { |m| "[#{m[:role]}]\n#{m[:content]}" }.join("\n\n")
      puts '--- Full prompt ---'.light_black
      puts full_text
      puts '--- End full prompt ---'.light_black
      puts
    end
    puts ask_running_line(prompt) if ask_show_running_line?(title)
    puts client.ask(messages, title: title)
  end

  def resolve_ask_prompt
    prompt, title = parse_ask_stdin($stdin.read)
    prompt = ARGV.join(' ').strip if prompt.to_s.strip.empty? && ARGV.any?
    if prompt.to_s.strip.empty?
      warn 'No prompt (stdin or argv).'
      exit 1
    end
    [prompt, title]
  end

  def parse_ask_stdin(stdin)
    return [stdin, nil] unless stdin.start_with?('TITLE:')

    line, rest = stdin.split("\n", 2)
    title = line.sub(/\ATITLE:\s*/, '').strip
    [rest.to_s.strip, title]
  end

  def ask_mode_client(progress_title: nil)
    OpenrouterClient.new(model: OpenrouterClient::DEFAULT_MODEL, debug: false, progress_title: progress_title)
  end

  def ask_mode_messages(prompt)
    system_msg = 'You are a request analyzer. Provide concise, structured responses. ' \
      'For external products or APIs, use web fetch to consult official docs to classify accurately.'

    [{role: 'system', content: system_msg}, {role: 'user', content: prompt}]
  end

  def ask_show_running_line?(title)
    title.to_s.strip != '' && !ask_mode_classification?(title)
  end

  def ask_running_line(prompt)
    excerpt = prompt.to_s.strip.lines.first.to_s.strip
    line = "agent ask"
    line += " #{excerpt.size > 72 ? "#{excerpt[0..68]}..." : excerpt}" if excerpt && !excerpt.empty?
    "Running: #{line}".green
  end
end
