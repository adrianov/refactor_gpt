# frozen_string_literal: true

module Quality
  # Repository concurrency gates: per-session presence marks so quality.rb
  # runs only for the last remaining agent on a git root, plus an exclusive
  # mkdir lock that serializes two agents that both become last at once.
  module RepoGates
    def active_lock_path(k); File.join(STATE, "quality-active-#{k}"); end
    def agent_mark_path(k); File.join(STATE, "quality-agent-#{k}-#{@session_key}"); end

    # Exclusive mkdir lock: at most one quality.rb process per git root.
    def claim_active(root)
      return true if root.nil? || root.empty?

      FileUtils.mkdir_p(STATE)
      key = Digest::SHA256.hexdigest(root)
      sweep_active_locks(key)
      return false unless acquire_lock(active_lock_path(key), ACTIVE_LOCK_AGE)

      @active_root_key = key
      true
    end

    def release_active
      path = active_lock_path(@active_root_key) if @active_root_key
      if path
        Dir.rmdir(path) if File.directory?(path)
        File.delete(path) if File.file?(path)
      end
    rescue StandardError
      nil
    ensure
      @active_root_key = nil
    end

    # Announce this session on the repo. Cleared when stepping aside (not last),
    # on finish_empty / stall, or when losing the exclusive lock race.
    def mark_agent(root)
      return if root.nil? || root.empty? || @session_key.empty?

      FileUtils.mkdir_p(STATE)
      @agent_root_key = Digest::SHA256.hexdigest(root)
      sweep_agent_marks(@agent_root_key)
      File.write(agent_mark_path(@agent_root_key), "#{Process.pid}\n#{Time.now.to_i}\n")
    end

    def release_agent
      path = agent_mark_path(@agent_root_key) if @agent_root_key && !@session_key.empty?
      File.delete(path) if path && File.file?(path)
    rescue StandardError
      nil
    ensure
      @agent_root_key = nil
    end

    # Last-one-out: drop our mark; true when no sibling marks remain.
    def last_agent?
      key = @agent_root_key
      release_agent
      return true if key.nil? || @session_key.empty?

      sweep_agent_marks(key)
      Dir.glob(File.join(STATE, "quality-agent-#{key}-*")).empty?
    end

    def sweep_active_locks(root_key)
      path = active_lock_path(root_key)
      drop_stale_dir_lock(path)
      File.delete(path) if File.file?(path)
      Dir.glob(File.join(STATE, "quality-active-#{root_key}-*")).each do |legacy|
        (File.delete(legacy) if File.file?(legacy)) rescue nil
      end
    rescue StandardError
      nil
    end

    def sweep_agent_marks(root_key)
      now = Time.now.to_i
      Dir.glob(File.join(STATE, "quality-agent-#{root_key}-*")).each do |path|
        (File.delete(path) if File.file?(path) && now - File.mtime(path).to_i >= AGENT_MARK_AGE) rescue nil
      end
    rescue StandardError
      nil
    end

    def drop_stale_dir_lock(path)
      return unless File.directory?(path)
      return if Time.now.to_i - File.mtime(path).to_i < ACTIVE_LOCK_AGE

      Dir.rmdir(path) rescue nil
    end

    def acquire_lock(dir, age = LOCK_AGE)
      true if Dir.mkdir(dir)
    rescue Errno::EEXIST
      mtime = File.mtime(dir).to_i rescue 0
      return false if Time.now.to_i - mtime < age

      Dir.rmdir(dir) rescue nil
      begin
        true if Dir.mkdir(dir)
      rescue Errno::EEXIST
        false
      end
    rescue StandardError
      false
    end
  end
end
