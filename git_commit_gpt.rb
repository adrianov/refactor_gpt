#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/loader"
require "colorize"

CompletionNotifier.setup_exit_hook
GitCommitSession.new(GitCommitOptions.parse(ARGV)).run
