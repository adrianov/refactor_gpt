# frozen_string_literal: true

# Shared config directory for superagent: sessions, history, and lock files.
module SuperagentConfig
  CONFIG_DIR = begin
    File.join(Dir.home, '.config', 'superagent')
  rescue ArgumentError
    File.join(Dir.tmpdir, 'superagent')
  end
end
