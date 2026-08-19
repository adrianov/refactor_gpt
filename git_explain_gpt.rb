#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/loader"

CompletionNotifier.setup_exit_hook
GitExplainSession.new(ARGV).run
