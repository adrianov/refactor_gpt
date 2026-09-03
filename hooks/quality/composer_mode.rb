# frozen_string_literal: true

module Quality
  # Cursor composer_mode from sessionStart: persist, expose, skip Ask stops.
  module ComposerMode
    def first_present(*values)
      values.find { |v| !v.to_s.empty? }.to_s
    end

    def session_start?
      return true if @input['hook_event_name'].to_s == 'sessionStart'

      !@input.key?('status') && @input.key?('composer_mode')
    end

    def remember_composer_mode
      mode = @input['composer_mode'].to_s.downcase
      mode = 'agent' if mode.empty?
      save_session_mode(mode)
      log_action('session_start', mode: mode)
      puts JSON.generate('env' => { 'QUALITY_COMPOSER_MODE' => mode })
      true
    end

    def composer_mode
      first_present(@input['composer_mode'], load_session_mode, ENV['QUALITY_COMPOSER_MODE']).downcase
    end
  end
end
