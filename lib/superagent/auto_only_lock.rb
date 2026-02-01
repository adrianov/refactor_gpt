# frozen_string_literal: true

require 'fileutils'

# Lock file in ~/.config/superagent: when present, superagent runs with model queue [auto, auto, auto] only.
# Created when a usage-related unrecoverable error is detected.
# Never expires; user must remove the file manually to exit auto-only mode.
module AutoOnlyLock
  LOCK_PATH = File.join(ConfigPath::CONFIG_DIR, 'auto_only')

  def self.path
    LOCK_PATH
  end

  def self.exist?
    File.exist?(path)
  end

  def self.create
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, Time.now.to_i.to_s)
  rescue StandardError
    nil
  end
end
