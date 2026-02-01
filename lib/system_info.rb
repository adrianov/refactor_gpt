# frozen_string_literal: true

require 'rbconfig'

# System information detection for ask_gpt and session context (OS, version, desktop).
class SystemInfo
  PLATFORM_PATTERNS = {/darwin/ => "macOS", /linux/ => "Linux",
                       /mswin|mingw|cygwin/ => "Windows"}.freeze

  def self.to_s
    @to_s ||= begin
      os = RbConfig::CONFIG["host_os"].downcase
      platform = detect_platform(os)
      version = detect_version(platform)
      desktop = detect_desktop
      format_info(platform, version, desktop)
    rescue StandardError
      ""
    end
  end

  def self.detect_platform(os)
    PLATFORM_PATTERNS.find { |p, _| os.match?(p) }&.last ||
      if os.match?(/linux/)
        if File.exist?("/etc/os-release") && File.read("/etc/os-release") =~ /^NAME="?Ubuntu"?/i
          "Ubuntu"
        else
          "Linux"
        end
      else
        RbConfig::CONFIG["host_os"]
      end
  end

  def self.detect_version(platform)
    case platform
    when "macOS" then `sw_vers -productVersion 2>/dev/null`.strip
    when "Ubuntu"
      return "" unless File.exist?("/etc/os-release")

      File.read("/etc/os-release").match(/^VERSION="?([^"\n]+)"?/)&.[](1)&.strip || ""
    when "Windows" then `wmic os get Version /value 2>NUL`.split("=").last.to_s.strip
    else ""
    end
  end

  def self.detect_desktop
    [
      ENV["XDG_CURRENT_DESKTOP"],
      ENV["DESKTOP_SESSION"],
      ENV["GNOME_DESKTOP_SESSION_ID"] ? "GNOME" : nil,
      (ENV["KDE_FULL_SESSION"] == "true") ? "KDE" : nil,
      ENV["XDG_SESSION_TYPE"]
    ].compact.join(" ")
  end

  def self.format_info(platform, version, desktop)
    info = "OS: #{platform}"
    info += ", Version: #{version}" unless version.empty?
    info += ", Desktop: #{desktop}" unless desktop.empty?
    info
  end

  def self.date_info
    `date`.strip
  rescue StandardError
    ""
  end
end
