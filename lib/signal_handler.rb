# frozen_string_literal: true

# Installs graceful SIGINT (Ctrl-C) handler so the process exits without a stack trace.
module SignalHandler
  EXIT_SIGINT = 130

  def self.install
    Signal.trap("INT") do
      $stderr.puts
      exit EXIT_SIGINT
    end
  end
end

SignalHandler.install
