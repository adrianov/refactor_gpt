# frozen_string_literal: true

require "fileutils"
require "digest"
require "tmpdir"

# Manages file-based locking to ensure only one instance runs per directory
module InstanceLock
  LOCK_DIR = File.join(Dir.tmpdir, "refactor_gpt_instance_locks")
  LOCK_CHECK_INTERVAL = 0.5

  def self.lock_file_path
    cwd = Dir.pwd
    lock_name = Digest::SHA256.hexdigest(cwd)
    File.join(LOCK_DIR, "#{lock_name}.lock")
  end

  def self.lock_exists?
    ensure_lock_dir
    lock_path = lock_file_path
    return false unless File.exist?(lock_path)
    return true if stale_lock?(lock_path)

    true
  end

  def self.ensure_lock_dir
    parent_dir = File.dirname(LOCK_DIR)
    if File.exist?(parent_dir) && !File.directory?(parent_dir)
      backup_path = "#{parent_dir}.backup.#{Time.now.to_i}"
      FileUtils.mv(parent_dir, backup_path)
      warn "Warning: #{parent_dir} was a file, moved to #{backup_path}"
    end
    FileUtils.mkdir_p(LOCK_DIR)
  end

  def self.acquire_lock(waiting_message: nil, &block)
    ensure_lock_dir
    lock_path = lock_file_path

    # Wait for lock to be released if another instance is running
    waiting_message_shown = false
    while File.exist?(lock_path)
      # Check if the lock is stale (process no longer running)
      if stale_lock?(lock_path)
        File.delete(lock_path) rescue nil
        break
      end

      unless waiting_message_shown
        waiting_message_shown = true
        if waiting_message
          warn waiting_message
        elsif block_given?
          yield
        end
      end

      sleep LOCK_CHECK_INTERVAL
    end

    # Create lock file with current PID
    File.write(lock_path, Process.pid.to_s)
    lock_path
  rescue StandardError => e
    warn "Warning: Failed to acquire lock: #{e.message}"
    nil
  end

  def self.stale_lock?(lock_path)
    return true unless File.exist?(lock_path)

    begin
      lock_pid = File.read(lock_path).to_i
      return true if lock_pid <= 0

      # Check if process is still running
      Process.kill(0, lock_pid)
      false
    rescue Errno::ESRCH, Errno::ENOENT
      # Process doesn't exist
      true
    rescue StandardError
      # If we can't check, assume it's not stale
      false
    end
  end

  def self.release_lock(lock_path)
    return unless lock_path && File.exist?(lock_path)

    # Verify we own the lock (check PID)
    begin
      lock_pid = File.read(lock_path).to_i
      if lock_pid == Process.pid
        File.delete(lock_path)
      end
    rescue StandardError => e
      warn "Warning: Failed to release lock: #{e.message}"
    end
  end

  def self.with_lock
    lock_path = acquire_lock
    return unless lock_path

    begin
      yield
    ensure
      release_lock(lock_path)
    end
  end
end
