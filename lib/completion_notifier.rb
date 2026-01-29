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

  def self.notify_completion(success: true, title: nil)
    return if @already_notified

    @already_notified = true
    @script_dir ||= find_project_root
    play_sound(success)
    set_terminal_title(title) if title
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

    script_dir = @script_dir || find_project_root
    sounds_dir = File.join(script_dir, 'sounds')
    sounds_path = File.join(sounds_dir, filename)
    return sounds_path if File.exist?(sounds_path)

    script_path = File.join(script_dir, filename)
    return script_path if File.exist?(script_path)

    nil
  end

  def self.find_project_root
    return @script_dir if @script_dir && File.exist?(File.join(@script_dir, 'sounds'))

    lib_dir = File.dirname(File.expand_path(__FILE__))
    project_root = File.dirname(lib_dir)
    return project_root if File.exist?(File.join(project_root, 'sounds'))

    script_dir = File.dirname(File.expand_path($PROGRAM_NAME))
    return script_dir if File.exist?(File.join(script_dir, 'sounds'))

    Dir.pwd if File.exist?(File.join(Dir.pwd, 'sounds'))
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
    @script_dir = find_project_root

    at_exit do
      # Skip notification if already notified (e.g., after analysis completion)
      unless @already_notified
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

  def self.set_terminal_title(title)
    return unless title

    # Prepend terminal title with short pwd
    project_root = find_project_root || Dir.pwd
    project_name = File.basename(project_root)
    title = "#{project_name}: #{title}"

    # Use ANSI escape sequence to set terminal title
    # \033]0; sets both icon and window title
    print "\033]0;#{title}\007"
    $stdout.flush
  rescue StandardError => e
    warn "Warning: Failed to set terminal title: #{e.message}" if ENV["DEBUG"]
  end
end
