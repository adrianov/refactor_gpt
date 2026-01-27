# frozen_string_literal: true

require "shellwords"

# Utility module for notifying task completion via sound and terminal title
module CompletionNotifier
  SUCCESS_SOUND = "success.aiff"
  ERROR_SOUND = "error.aiff"

  @exit_status = nil
  @exception_occurred = false
  @script_dir = nil

  def self.notify_completion(success: true)
    play_sound(success)
    update_terminal_title(success)
  end

  def self.play_sound(success)
    sound_file = success ? SUCCESS_SOUND : ERROR_SOUND
    sound_path = find_sound_file(sound_file)
    return unless sound_path

    system("afplay #{sound_path.shellescape} > #{File::NULL} 2>&1")
  rescue StandardError
    # Ignore sound playback errors
  end

  def self.find_sound_file(filename)
    return File.expand_path(filename) if File.exist?(filename)

    script_dir = @script_dir || File.dirname(File.expand_path($PROGRAM_NAME))
    script_path = File.join(script_dir, filename)
    return script_path if File.exist?(script_path)

    nil
  end

  def self.update_terminal_title(success)
    status = success ? "✓ Done" : "✗ Error"
    # \e]0;TITLE\a is the escape sequence for setting the terminal title
    print "\e]0;#{status}\a"
    $stdout.flush
  rescue StandardError
    # Ignore terminal title update errors
  end

  def self.set_exit_status(status)
    @exit_status = status
  end

  def self.mark_exception
    @exception_occurred = true
  end

  def self.setup_exit_hook
    @script_dir = File.dirname(File.expand_path($PROGRAM_NAME))

    trap("EXIT") do |status|
      exit_code = status.is_a?(Integer) ? status : (status.respond_to?(:to_i) ? status.to_i : 0)
      set_exit_status(exit_code)
    end

    at_exit do
      success = determine_success
      notify_completion(success: success)
    end
  end

  def self.determine_success
    return false if @exception_occurred

    if @exit_status
      return @exit_status == 0
    end

    if $!
      return false unless $!.is_a?(SystemExit)
      return $!.status == 0 if $!.status
    end

    return $?.success? if $?

    true
  end

  def self.exit_with_status(code)
    set_exit_status(code)
    exit(code)
  end

  def self.wrap_main
    yield
  rescue SystemExit => e
    set_exit_status(e.status)
    raise
  rescue StandardError => e
    mark_exception
    raise
  end
end
