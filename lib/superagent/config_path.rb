# frozen_string_literal: true

require 'digest'

# Shared config directory and project identification for superagent: sessions, history, and lock files.
# Project is identified by directory (cwd); many sessions per project stored in one file per project.
module ConfigPath
  CONFIG_DIR = begin
    File.join(Dir.home, '.config', 'superagent')
  rescue ArgumentError
    File.join(Dir.tmpdir, 'superagent')
  end

  def self.project_id(cwd = Dir.pwd)
    Digest::SHA256.hexdigest(cwd)
  end
end
