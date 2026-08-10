#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/loader"
require "colorize"

CompletionNotifier.setup_exit_hook
options = GitCommitOptions.parse(ARGV)
CompletionNotifier.mute! if options.auto
GitCommitSession.new(options).run
