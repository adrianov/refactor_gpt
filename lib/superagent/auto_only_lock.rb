# frozen_string_literal: true

# Lock file in project root: when present, superagent runs with model queue [auto, auto, auto] only.
# Created when a usage-related unrecoverable error is detected.
module AutoOnlyLock
  LOCK_FILENAME = '.superagent_auto_only'

  def self.path
    File.join(Dir.pwd, LOCK_FILENAME)
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
