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
SUPERAGENT_CLI_STRIP_FLAGS = %w[--skip-midnight --no-midnight --debug --mode].freeze

def parse_superagent_cli_options
  ask_mode = false
  if (idx = ARGV.index('--mode'))
    val = ARGV[idx + 1]
    ask_mode = (val == 'ask')
    ARGV.delete_at(idx + 1) if val
    ARGV.delete_at(idx)
  end
  skip_midnight_check = ARGV.include?('--skip-midnight') || ARGV.include?('--no-midnight')
  show_full_prompt = ARGV.include?('--debug')
  ARGV.reject! { |a| SUPERAGENT_CLI_STRIP_FLAGS.include?(a) }
  { ask_mode: ask_mode, skip_midnight_check: skip_midnight_check, show_full_prompt: show_full_prompt }
end

def ask_mode_classification?(title)
  ['Classifying to a session', 'Classifying request'].include?(title.to_s.strip)
end

def run_ask_mode
  sandbox = "/tmp/sandbox_#{Random.hex(8)}"
  FileUtils.mkdir_p(sandbox)
  original_cwd = Dir.pwd
  Dir.chdir(sandbox)
  begin
    prompt, title = resolve_ask_prompt
    config = ask_mode_config
    unless config
      warn 'No API configuration. Set MODEL (or token) in .env'
      exit 1
    end
    classification = ask_mode_classification?(title)
    client = ask_mode_client(config, progress_title: classification ? nil : 'Thinking')
    invoke_ask_client(client, config, prompt, classification ? nil : title)
    exit 0
  ensure
    Dir.chdir(original_cwd)
    FileUtils.rm_rf(sandbox)
  end
end

def invoke_ask_client(client, config, prompt, title)
  messages = ask_mode_messages(config[:backend], prompt)
  excerpt = prompt.to_s.strip.lines.first.to_s.strip
  run_line = "agent --mode ask"
  run_line += " #{excerpt.size > 72 ? "#{excerpt[0..68]}..." : excerpt}" if excerpt && !excerpt.empty?
  puts "Running: #{run_line}".green
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

def ask_mode_config
  env = ENV.to_h.merge(Utility.load_env_vars)
  # Ask mode always uses "auto" resolution: backend default from tokens, ignore MODEL in .env.
  env_auto = env.merge('MODEL' => '')
  LlmRouter.config_for_model(LlmRouter.default_model(env_auto), env)
end

def ask_mode_client(config, progress_title: 'Thinking')
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
      Runs the agent; request can be given as an argument or entered interactively.
      Only one instance per project; if another is running, this process exits.
      Options:
        -h, --help           Show this help
        --debug              Show full system prompt
        --mode ask           Sandboxed one-shot Q&A (stdin: optional "TITLE: ...\\n\\n" then prompt; stdout: response)
        --skip-midnight, --no-midnight   Skip midnight-rollover check
    HELP
    exit 0
  end

  options = parse_superagent_cli_options
  if options[:ask_mode]
    run_ask_mode
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
