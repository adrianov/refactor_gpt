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
require 'colorize'
require_relative "lib/superagent/display"
require_relative "lib/superagent/request_reader"
require_relative "lib/superagent/agent_executor"
require_relative "lib/superagent/verification_handler"
require_relative "lib/superagent/superagent"
require_relative "lib/superagent/auto_only_lock"
require_relative "lib/completion_notifier"
require_relative "lib/instance_lock"

if __FILE__ == $PROGRAM_NAME
  CompletionNotifier.setup_exit_hook
  skip_midnight_check = ARGV.include?('--skip-midnight') || ARGV.include?('--no-midnight')
  ARGV.delete('--skip-midnight')
  ARGV.delete('--no-midnight')
  resume_enabled = ARGV.include?('--resume')
  ARGV.delete('--resume')

  display = Display.new(skip_midnight_check: skip_midnight_check)
  auto_only = AutoOnlyLock.exist?
  display.puts 'Auto-only lock file is set; running in auto-only mode.'.yellow if auto_only
  suggestion = CompletionNotifier.sound_install_suggestion
  display.puts suggestion.yellow if suggestion
  lock_path = nil
  request_reader = RequestReader.new(display)

  begin
    if InstanceLock.lock_exists?
      $stdout.puts ''
      display.puts 'Another instance is running in the current directory.'.yellow
      display.puts 'Enter your request to add it to the queue.'.yellow
      $stdout.puts ''
      pre_read_request = request_reader.read
      request_reader.validate(pre_read_request)
      InstanceLock.append_pending_request(pre_read_request)
      display.puts 'Request queued.'.green
      exit 0
    end

    lock_path = InstanceLock.acquire_lock

    unless lock_path
      display.puts 'Failed to acquire instance lock. Exiting.'.red
      exit 1
    end

    Superagent.new(
      display: display, request_reader: request_reader, auto_only: auto_only, resume_enabled: resume_enabled
    ).run
  ensure
    InstanceLock.release_lock(lock_path) if lock_path
  end
end
