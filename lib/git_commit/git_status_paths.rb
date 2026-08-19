# frozen_string_literal: true

require "open3"

# Parses `git status --porcelain` (and R100-style) lines into path lists.
# Rename/copy lines yield both the source and the destination.
module GitStatusPaths
  LINE = /\A(?:[A-Z]\d+|[MTADRCU?! ]{2})\s+(.*)\z/

  module_function

  def filenames(porcelain)
    entries(porcelain).flat_map(&:last).uniq
  end

  def expand_partners(paths)
    selected = Array(paths).map(&:to_s).reject(&:empty?).uniq
    return selected if selected.empty?

    out, _, status = Open3.capture3("git", "status", "--porcelain")
    return selected unless status.success?

    (selected + partners_for(selected, out)).uniq
  end

  def entries(porcelain)
    porcelain.to_s.split("\n").filter_map { |line| parse_line(line) }
  end

  def partners_for(selected, porcelain)
    set = Array(selected).map(&:to_s).reject(&:empty?).to_set
    return [] if set.empty?

    dirs = set.flat_map { |path| nearby_dirs(path) }.to_set
    entries(porcelain).flat_map { |code, paths| partner_paths(code, paths, set, dirs) }.uniq
  end

  def partner_paths(code, paths, set, dirs)
    return [] unless deletion_or_rename?(code, paths)
    return paths if paths.any? { |path| set.include?(path) }
    return paths if paths.any? { |path| dirs.include?(File.dirname(path)) }

    []
  end

  def parse_line(line)
    return if line.strip.empty? || line.start_with?("##")

    rest = line[LINE, 1] || line.sub(/\A.{2}\s+/, "")
    paths = rest.split(/\s+->\s+/).map { |part| unquote(part.strip) }.reject(&:empty?)
    return if paths.empty?

    [line[0, 2], paths]
  end

  def unquote(path)
    path.match(/\A"(.*)"\z/) ? Regexp.last_match(1) : path
  end

  def deletion_or_rename?(code, paths)
    return true if paths.size > 1

    code.to_s.chars.any? { |char| %w[D R C].include?(char) }
  end

  def nearby_dirs(path)
    dir = File.dirname(path.to_s)
    return [] if dir == "." || dir.empty?

    parent = File.dirname(dir)
    parent == "." ? [dir] : [dir, parent]
  end
end
