#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Superagent - Automated code agent with multi-model fallback and verification
# Copyright 2026 Peter Adrianov
# Email: peter.adrianov@gmail.com
# Telegram: @adrianov
#
# Executes agent commands across multiple AI models sequentially,
# automatically verifying results and retrying with fix instructions when verification fails.
# Only lib/loader is required; do not load root _gpt scripts (ask_gpt, etc.).

require_relative "lib/loader"
require "colorize"
require "fileutils"
InstanceLock.lock_dir_override = ConfigPath::CONFIG_DIR

# Option strings stripped from ARGV by parse_superagent_cli_options. Add new flags here when adding options.
SUPERAGENT_CLI_STRIP_FLAGS = %w[--skip-midnight --no-midnight --debug --stdin-commands].freeze

def parse_superagent_cli_options
  ask_mode = (ARGV.first == 'ask')
  ARGV.shift if ask_mode
  skip_midnight_check = ARGV.include?('--skip-midnight') || ARGV.include?('--no-midnight')
  show_full_prompt = ARGV.include?('--debug')
  stdin_commands = ARGV.include?('--stdin-commands')
  ARGV.reject! { |a| SUPERAGENT_CLI_STRIP_FLAGS.include?(a) }
  { ask_mode: ask_mode, skip_midnight_check: skip_midnight_check, show_full_prompt: show_full_prompt,
    stdin_commands: stdin_commands }
end

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
  config = ask_mode_config
  unless config
    warn 'No API configuration. Set MODEL (or token) in .env'
    exit 1
  end
  classification = ask_mode_classification?(title)
  client = ask_mode_client(config)
  invoke_ask_client(client, config, prompt, classification ? nil : title, show_full_prompt: show_full_prompt)
  exit 0
end

def run_ask_mode_interactive(show_full_prompt: false)
  display = Display.new
  request_reader = RequestReader.new(display)
  prompt, title = resolve_ask_prompt_interactive(request_reader)
  exit 0 if prompt.to_s.strip.empty?

  config = ask_mode_config
  unless config
    warn 'No API configuration. Set MODEL (or token) in .env'
    exit 1
  end
  queue, worker = start_ask_worker(prompt, title, config, show_full_prompt)
  run_ask_main_input_loop(queue, request_reader, display)
  queue << :quit
  worker.join
  exit 0
end

def start_ask_worker(prompt, title, config, show_full_prompt)
  client = ask_mode_client(config)
  queue = Queue.new
  queue << { prompt: prompt, title: title }
  worker = Thread.new { ask_worker_loop(queue, client, config, show_full_prompt) }
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

def ask_worker_loop(queue, client, config, show_full_prompt)
  loop do
    item = queue.pop
    break if item == :quit

    classification = ask_mode_classification?(item[:title])
    invoke_ask_client(client, config, item[:prompt], classification ? nil : item[:title],
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
  return :next if raw.nil? || raw.to_s.strip.empty?

  text = RequestPreparer.normalized_request_text(raw)
  request_reader.add_to_request_history(raw)
  queue << { prompt: text, title: nil }
  display.puts "Queued: #{RequestHistoryFormatter.queue_preview(text)}".light_blue
  :next
end

def invoke_ask_client(client, config, prompt, title, show_full_prompt: false)
  messages = ask_mode_messages(config[:backend], prompt)
  if show_full_prompt
    full_text = messages.map { |m| "[#{m[:role]}]\n#{m[:content]}" }.join("\n\n")
    puts '--- Full prompt ---'.light_black
    puts full_text
    puts '--- End prompt ---'.light_black
  end
  puts ask_running_line(prompt) if ask_show_running_line?(title)
  puts client.ask(messages, title: title)
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

def ask_mode_config
  env = ENV.to_h.merge(Utility.load_env_vars)
  # Ask mode always uses "auto" resolution: backend default from tokens, ignore MODEL in .env.
  env_auto = env.merge('MODEL' => '')
  LlmRouter.config_for_model(LlmRouter.default_model(env_auto), env)
end

def ask_mode_client(config, progress_title: nil)
  common = { model: config[:model], api_base_url: config[:base_url], api_key: config[:access_token],
             debug: false, progress_title: progress_title }
  config[:backend] == :gemini ? GeminiClient.new(**common) : OpenAiClient.new(**common)
end

def ask_mode_messages(backend, prompt)
  return [{role: 'user', content: prompt}] if backend == :gemini

  system_msg = 'You are a request analyzer. Provide concise, structured responses. ' \
    'For external products or APIs, use web fetch to consult official docs to classify accurately.'
  [{role: 'system', content: system_msg}, {role: 'user', content: prompt}]
end

if __FILE__ == $PROGRAM_NAME
  if ARGV.include?('--help') || ARGV.include?('-h')
    puts <<~HELP
      Usage: #{File.basename($PROGRAM_NAME)} [options] [request]
             #{File.basename($PROGRAM_NAME)} ask [question]
      Runs the agent; request can be given as an argument or entered interactively.
      Subcommand 'ask': one-shot Q&A from stdin or ARGV; in a TTY, press Enter to add more requests (type /quit to exit).
      Only one instance per project; if another is running, this process exits.
      Options:
        -h, --help           Show this help
        --debug              Show full system prompt
        --skip-midnight, --no-midnight   Skip midnight-rollover check
        --stdin-commands     Reuse agent process: read JSON job lines from stdin, run one agent step per job, write {"done":true,"code":N} to stdout
    HELP
    exit 0
  end

  options = parse_superagent_cli_options
  if options[:stdin_commands]
    StdinCommandsRunner.new(stdin: $stdin, stdout: $stdout, stderr: $stderr).run
    exit 0
  end
  if options[:ask_mode]
    run_ask_mode(show_full_prompt: options[:show_full_prompt])
    # run_ask_mode exits; never reached
  end

  CompletionNotifier.setup_exit_hook
  display = Display.new(skip_midnight_check: options[:skip_midnight_check])
  auto_only = AutoOnlyLock.exist?
  if auto_only
    display.puts 'Auto-only lock file is set; running in auto-only mode.'.yellow
    display.puts "Remove it manually when you want to exit: rm #{AutoOnlyLock.path}".yellow
  end
  suggestion = CompletionNotifier.sound_install_suggestion
  display.puts suggestion.yellow if suggestion
  lock_path = nil
  request_reader = RequestReader.new(display)

  begin
    lock_path = InstanceLock.acquire_lock
    unless lock_path
      base_name = InstanceLock.project_base_name
      display.puts "Another instance is already running for this project (#{base_name}). Exiting.".red
      exit 1
    end

    Superagent.new(
      display: display, request_reader: request_reader, auto_only: auto_only,
      show_full_prompt: options[:show_full_prompt]
    ).run
  ensure
    InstanceLock.release_lock(lock_path) if lock_path
  end
end
