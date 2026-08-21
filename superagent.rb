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
SUPERAGENT_CLI_STRIP_FLAGS = %w[--skip-midnight --no-midnight --debug].freeze

def parse_superagent_cli_options
  ask_mode = (ARGV.first == 'ask')
  ARGV.shift if ask_mode
  skip_midnight_check = ARGV.include?('--skip-midnight') || ARGV.include?('--no-midnight')
  show_full_prompt = ARGV.include?('--debug')
  ARGV.reject! { |a| SUPERAGENT_CLI_STRIP_FLAGS.include?(a) }
  { ask_mode: ask_mode, skip_midnight_check: skip_midnight_check, show_full_prompt: show_full_prompt }
end

def print_superagent_help
  puts <<~HELP
    Usage: #{File.basename($PROGRAM_NAME)} [options] [request]
           #{File.basename($PROGRAM_NAME)} ask [question]
    Runs the agent; request can be given as an argument or entered interactively.
    After each run, prompts for next request (same directory); type /quit to exit.
    Subcommand 'ask': one-shot Q&A from stdin or ARGV; in a TTY, press Enter to add more requests (type /quit to exit).
    Only one instance per project; if another is running, this process exits.
    Options:
      -h, --help           Show this help
      --debug              Show full system prompt
      --skip-midnight, --no-midnight   Skip midnight-rollover check
  HELP
  exit 0
end

def handle_ask_mode_option(options)
  return unless options[:ask_mode]

  AskModeRunner.run_ask_mode(show_full_prompt: options[:show_full_prompt])
  # run_ask_mode exits; never reached
end

def print_auto_only_notice(display)
  auto_only = AutoOnlyLock.exist?
  return auto_only unless auto_only

  display.puts 'Auto-only lock file is set; running in auto-only mode.'.yellow
  display.puts "Remove it manually when you want to exit: rm #{AutoOnlyLock.path}".yellow
  auto_only
end

def print_sound_suggestion(display)
  suggestion = CompletionNotifier.sound_install_suggestion
  display.puts suggestion.yellow if suggestion
end

def acquire_lock_or_exit(display)
  lock_path = InstanceLock.acquire_lock
  return lock_path if lock_path

  display.puts "Another instance is already running for this project (#{InstanceLock.project_base_name}). Exiting.".red
  exit 1
end

def run_superagent_session(display, request_reader, options, auto_only)
  Superagent.new(
    display: display, request_reader: request_reader, auto_only: auto_only,
    show_full_prompt: options[:show_full_prompt]
  ).run
end

if __FILE__ == $PROGRAM_NAME
  print_superagent_help if ARGV.include?('--help') || ARGV.include?('-h')

  options = parse_superagent_cli_options
  handle_ask_mode_option(options)

  CompletionNotifier.setup_exit_hook
  display = Display.new(skip_midnight_check: options[:skip_midnight_check])
  auto_only = print_auto_only_notice(display)
  print_sound_suggestion(display)
  request_reader = RequestReader.new(display)

  lock_path = nil
  begin
    lock_path = acquire_lock_or_exit(display)
    run_superagent_session(display, request_reader, options, auto_only)
  ensure
    InstanceLock.release_lock(lock_path) if lock_path
  end
end
