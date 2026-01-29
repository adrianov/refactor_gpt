# frozen_string_literal: true

# Lock file in user home: when present, superagent runs with model queue [auto, auto, auto] only.
# Created when a usage-related unrecoverable error is detected.
module AutoOnlyLock
  LOCK_FILENAME = '.superagent_auto_only'

  LOCK_PATH = begin
    File.join(Dir.home, LOCK_FILENAME)
  rescue ArgumentError
    File.join(Dir.tmpdir, LOCK_FILENAME)
  end

  def self.path
    LOCK_PATH
  end

  def self.exist?
    File.exist?(path)
  end

  def self.create
    File.write(path, Time.now.to_i.to_s)
  rescue StandardError
    nil
  end
end
