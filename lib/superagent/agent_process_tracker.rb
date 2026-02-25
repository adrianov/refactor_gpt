# frozen_string_literal: true

# Tracks running agent child PIDs and terminates them on SIGINT/SIGTERM.
class AgentProcessTracker
  def initialize
    @pids = []
    @mutex = Mutex.new
    SignalHandler.install(method(:kill_all))
  end

  def register(pid)
    return unless pid

    @mutex.synchronize { @pids << pid unless @pids.include?(pid) }
  end

  def unregister(pid)
    return unless pid

    @mutex.synchronize { @pids.delete(pid) }
  end

  def kill_all
    @mutex.synchronize { @pids.dup }.each { |pid| kill_pid(pid) }
  end

  private

  def kill_pid(pid)
    Process.kill('TERM', pid)
    sleep 0.5
    Process.kill('KILL', pid) unless Process.waitpid(pid, Process::WNOHANG)
  rescue Errno::ESRCH, Errno::ECHILD
    # Process already exited
  end
end
