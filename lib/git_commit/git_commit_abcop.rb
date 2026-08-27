# frozen_string_literal: true

# Suggests the abcop command covering pending changes before committing.
module GitCommitAbcop
  module_function

  CODE_EXTENSIONS = %w[.rb .rake .ru .gemspec .rs].freeze
  SKIP_PATHS = %w[db/schema.rb].freeze

  # Returns a shell command string the user can copy and run, or nil when no
  # analysable code changed.
  def suggestion(status_output)
    return nil if repository_root.nil?
    return nil if changed_code_paths(status_output).empty?

    'abcop'
  end

  private_class_method def repository_root
    out = `git rev-parse --show-toplevel 2>/dev/null`.strip
    $?.success? ? out : nil
  end

  private_class_method def changed_code_paths(status_output)
    raw = status_output.to_s.strip.empty? ? `git status --porcelain --branch` : status_output
    porcelain_paths(raw).filter_map do |rel|
      rel = rel.gsub("\\", "/")
      next if SKIP_PATHS.include?(rel)

      rel if CODE_EXTENSIONS.include?(File.extname(rel).downcase) && !rel.end_with?("/")
    end.uniq
  end

  private_class_method def porcelain_paths(output)
    output.split("\n").filter_map do |line|
      next if line.strip.empty? || line.start_with?("##")

      path = line.sub(/^.{2}\s+/, "")
      path = path.split("->").last.strip if path.include?("->")
      path.match(/\A"(.*)"\z/) ? Regexp.last_match(1) : path
    end
  end
end
