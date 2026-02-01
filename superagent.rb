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
InstanceLock.lock_dir_override = ConfigPath::CONFIG_DIR

# Option strings stripped from ARGV by parse_superagent_cli_options. Add new flags here when adding options.
SUPERAGENT_CLI_STRIP_FLAGS = %w[--skip-midnight --no-midnight --debug].freeze

def parse_superagent_cli_options
  skip_midnight_check = ARGV.include?('--skip-midnight') || ARGV.include?('--no-midnight')
  show_full_prompt = ARGV.include?('--debug')
  ARGV.reject! { |a| SUPERAGENT_CLI_STRIP_FLAGS.include?(a) }
  { skip_midnight_check: skip_midnight_check, show_full_prompt: show_full_prompt }
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
        --skip-midnight, --no-midnight   Skip midnight-rollover check
    HELP
    exit 0
  end

  CompletionNotifier.setup_exit_hook
  options = parse_superagent_cli_options
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
