# frozen_string_literal: true

require "rbconfig"
require "shellwords"

# Utility module for notifying task completion via sound and terminal title
module CompletionNotifier
  SUCCESS_BASE = "success"
  ERROR_BASE = "error"

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
    play_cmd = sound_play_command
    return unless play_cmd

    base = success ? SUCCESS_BASE : ERROR_BASE
    sound_path = find_sound_file(base)

    spawn_sound(play_cmd, sound_path) if sound_path
  rescue StandardError => e
    warn "Warning: Sound playback failed: #{e.message}" if ENV["DEBUG"]
  end

  def self.darwin?
    RbConfig::CONFIG["host_os"].to_s.include?("darwin")
  end

  def self.sound_play_command
    if darwin?
      return ["afplay"] if command_exists?("afplay")
      return nil
    end

    [
      ["paplay"],
      ["aplay", "-q"],
      ["ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet"]
    ].find { |cmd| command_exists?(cmd[0]) }
  end

  def self.sound_player_available?
    !sound_play_command.nil?
  end

  def self.sound_install_suggestion
    return nil if sound_player_available?

    if darwin?
      'Completion sounds need afplay (usually present on macOS).'
    else
      'To enable completion sounds, install paplay (pulseaudio-utils) or aplay (alsa-utils).'
    end
  end

  def self.spawn_sound(play_cmd, path)
    args = play_cmd.size > 1 ? play_cmd[1..] + [path] : [path]
    pid = Process.spawn(play_cmd[0], *args, out: File::NULL, err: File::NULL)
    Process.detach(pid)
  end

  def self.command_exists?(command)
    system("command -v #{command.shellescape} > #{File::NULL} 2>&1")
  end

  def self.find_sound_file(base_name)
    script_dir = @script_dir || find_project_root
    sounds_dir = File.join(script_dir, 'sounds')
    exts = %w[.wav]
    exts.each do |ext|
      path = File.join(sounds_dir, "#{base_name}#{ext}")
      return path if File.exist?(path)
    end
    exts.each do |ext|
      path = File.join(script_dir, "#{base_name}#{ext}")
      return path if File.exist?(path)
    end
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
