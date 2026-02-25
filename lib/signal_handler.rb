# frozen_string_literal: true

# Installs graceful SIGINT (Ctrl-C) handler so the process exits without a stack trace.
module SignalHandler
  EXIT_SIGINT = 130

  def self.install(cleanup_proc = nil)
    Signal.trap("INT") do
      $stderr.puts
      cleanup_proc&.call
      exit EXIT_SIGINT
    end
    Signal.trap("TERM") do
      cleanup_proc&.call
      exit 0
    end
  end
end

# SignalHandler.install is called by components that need it
