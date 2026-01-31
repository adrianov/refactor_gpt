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

require_relative "lib/signal_handler"
require_relative "lib/superagent/config_path"
require 'colorize'
require_relative "lib/superagent/display"
require_relative "lib/superagent/request_reader"
require_relative "lib/superagent/agent_executor"
require_relative "lib/superagent/verification_handler"
require_relative "lib/superagent/superagent"
require_relative "lib/superagent/auto_only_lock"
require_relative "lib/completion_notifier"
require_relative "lib/instance_lock"
InstanceLock.lock_dir_override = SuperagentConfig::CONFIG_DIR

if __FILE__ == $PROGRAM_NAME
  if ARGV.include?('--help') || ARGV.include?('-h')
    puts <<~HELP
      Usage: #{File.basename($PROGRAM_NAME)} [options] [request]
      Runs the agent; request can be given as an argument or entered interactively.
      Only one instance per project; if another is running, this process exits.
      Options:
        -h, --help           Show this help
        --show-prompt        Show the system prompt (default)
        --no-show-prompt     Do not show the system prompt
        --skip-midnight, --no-midnight   Skip midnight-rollover check
    HELP
    exit 0
  end

  CompletionNotifier.setup_exit_hook
  skip_midnight_check = ARGV.include?('--skip-midnight') || ARGV.include?('--no-midnight')
  show_prompt = true
  show_prompt = false if ARGV.include?('--no-show-prompt')
  ARGV.reject! { |a| %w[--skip-midnight --no-midnight --show-prompt --no-show-prompt].include?(a) }

  display = Display.new(skip_midnight_check: skip_midnight_check)
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
      show_prompt: show_prompt
    ).run
  ensure
    InstanceLock.release_lock(lock_path) if lock_path
  end
end
