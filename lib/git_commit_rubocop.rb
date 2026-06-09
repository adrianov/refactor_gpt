# frozen_string_literal: true

require "shellwords"

# Builds a ready-to-copy RuboCop autocorrect command for changed Ruby files.
# Uses `bundle exec rubocop` when a Gemfile is present in the repository root.
module GitCommitRubocop
  module_function

  RUBY_EXTENSIONS = %w[.rb .rake .gemspec].freeze
  SKIP_PATHS = %w[db/schema.rb].freeze

  # Returns a shell command string the user can copy and run, or nil when no Ruby files changed.
  def suggestion(status_output)
    git_root = repository_root
    return nil if git_root.nil?

    paths = changed_ruby_paths(status_output, git_root)
    return nil if paths.empty?

    prefix = File.file?(File.join(git_root, "Gemfile")) ? "bundle exec rubocop" : "rubocop"
    "#{prefix} -a -- #{Shellwords.shelljoin(paths)}"
  end

  private_class_method def repository_root
    out = `git rev-parse --show-toplevel 2>/dev/null`.strip
    $?.success? ? out : nil
  end

  private_class_method def changed_ruby_paths(status_output, git_root)
    raw = status_output.to_s.strip.empty? ? `git status --porcelain --branch` : status_output
    porcelain_paths(raw).filter_map do |rel|
      rel = rel.gsub("\\", "/")
      next if SKIP_PATHS.include?(rel)
      next unless RUBY_EXTENSIONS.include?(File.extname(rel).downcase) && !rel.end_with?("/")

      File.file?(File.expand_path(rel, git_root)) ? rel : nil
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
