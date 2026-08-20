# frozen_string_literal: true

# Detects CLI file pathspecs vs free-text (including deleted paths known to git), and filters by extension.
module CliPaths
  module_function

  def path_arg?(arg)
    File.exist?(arg) || arg.include?("/") || arg.start_with?(".") || GitPathspec.known_to_git?(arg)
  end

  def supported?(path, extensions)
    return true if extensions.nil? || extensions.empty?
    return true if File.directory?(path.to_s)

    ext = File.extname(path.to_s).downcase
    ext.empty? || extensions.include?(ext)
  end

  def select_supported(paths, extensions)
    Array(paths).map(&:to_s).reject(&:empty?).select { |path| supported?(path, extensions) }
  end

  def partition(args)
    paths = []
    rest = []
    i = 0
    while i < args.length
      i = take_one(args, i, paths, rest)
    end
    [rest, paths.uniq]
  end

  def take_one(args, index, paths, rest)
    arg = args[index]
    return take_tail(args, index, paths) if arg == "--"
    return take_file_eq(arg, index, paths) if arg.start_with?("--file=")
    return take_file_flag(args, index, paths) if arg == "--file"

    (path_arg?(arg) ? paths : rest) << arg
    index + 1
  end

  def take_tail(args, index, paths)
    paths.concat(args[(index + 1)..] || [])
    args.length
  end

  def take_file_eq(arg, index, paths)
    paths << arg.delete_prefix("--file=")
    index + 1
  end

  def take_file_flag(args, index, paths)
    paths << args[index + 1].to_s
    index + 2
  end
end
