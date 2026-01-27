# frozen_string_literal: true

require "shellwords"

# Utility module for notifying task completion via sound and terminal title
module CompletionNotifier
  SUCCESS_SOUND = "success.aiff"
  ERROR_SOUND = "error.aiff"

  @exit_status = nil
  @exception_occurred = false
  @script_dir = nil
  @already_notified = false

  def self.notify_completion(success: true)
    @already_notified = true
    play_sound(success)
    update_terminal_title(success)
  end

  def self.play_sound(success)
    return unless command_exists?("afplay")

    sound_file = success ? SUCCESS_SOUND : ERROR_SOUND
    sound_path = find_sound_file(sound_file)

    if sound_path
      pid = Process.spawn("afplay", sound_path, out: File::NULL, err: File::NULL)
      Process.detach(pid)
    else
      # Fallback to system sounds if local files are missing
      system_sound = success ? "/System/Library/Sounds/Glass.aiff" : "/System/Library/Sounds/Basso.aiff"
      if File.exist?(system_sound)
        pid = Process.spawn("afplay", system_sound, out: File::NULL, err: File::NULL)
        Process.detach(pid)
      end
    end
  rescue StandardError => e
    warn "Warning: Sound playback failed: #{e.message}" if ENV["DEBUG"]
  end

  def self.command_exists?(command)
    system("command -v #{command.shellescape} > #{File::NULL} 2>&1")
  end

  def self.find_sound_file(filename)
    return File.expand_path(filename) if File.exist?(filename)

    script_dir = @script_dir || File.dirname(File.expand_path($PROGRAM_NAME))
    sounds_dir = File.join(script_dir, 'sounds')
    sounds_path = File.join(sounds_dir, filename)
    return sounds_path if File.exist?(sounds_path)

    script_path = File.join(script_dir, filename)
    return script_path if File.exist?(script_path)

    nil
  end

  def self.update_terminal_title(success)
    return unless $stdout.tty? || $stderr.tty?

    status = success ? "✓ Done" : "✗ Error"
    # Use \033 instead of \e for better compatibility, and \007 instead of \a
    # This works with Terminal.app, iTerm2, and most xterm-compatible terminals
    sequence = "\033]2;#{status}\007\033]1;#{status}\007"
    $stdout.print sequence if $stdout.tty?
    $stdout.flush if $stdout.tty?
    $stderr.print sequence if $stderr.tty?
    $stderr.flush if $stderr.tty?
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
    return if @hook_setup

    @hook_setup = true
    @script_dir = File.dirname(File.expand_path($PROGRAM_NAME))

    at_exit do
      # Skip notification if already notified (e.g., after analysis completion)
      return if @already_notified

      # Capture exit status from global exception if available
      if $!.is_a?(SystemExit)
        set_exit_status($!.status)
      elsif $!
        mark_exception
      end

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
    setup_exit_hook
    yield
  rescue SystemExit => e
    set_exit_status(e.status)
    raise
  rescue StandardError => e
    mark_exception
    raise
  end
end
