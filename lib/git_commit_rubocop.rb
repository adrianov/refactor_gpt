# frozen_string_literal: true

require "open3"
require "shellwords"
require "colorize"

# Autocorrects changed Ruby files with RuboCop before commit planning (when the repo
# uses RuboCop). Exits if offenses remain after autocorrect.
module GitCommitRubocop
  module_function

  RUBY_LINT_EXTENSIONS = %w[.rb .rake .gemspec].freeze

  # Runs `rubocop -a` on changed Ruby sources; exits non-zero when offenses remain.
  def autocorrect_before_plan!(status_output)
    return unless project_rubocop_ready?

    paths = rubocop_target_paths(status_output)
    return if paths.empty?

    cmd = Shellwords.shelljoin(["rubocop", "-a", "--", *paths])
    puts "Running: #{cmd}".green
    return if system("rubocop", "-a", "--", *paths)

    warn "RuboCop reported offenses that remain after autocorrect; fix or exclude them manually.".red
    exit 1
  end

  def project_rubocop_enabled?(root = Dir.pwd)
    %w[.rubocop.yml .rubocop_todo.yml].any? { |name| File.file?(File.join(root, name)) }
  end

  def rubocop_available?
    _out, st = Open3.capture2("rubocop", "-V")
    st.success?
  end

  def project_rubocop_ready?
    project_rubocop_enabled? && rubocop_available?
  end

  def porcelain_file_paths(porcelain_output)
    porcelain_output.split("\n").map do |line|
      next nil if line.strip.empty? || line.start_with?("##")

      status_and_path = line.sub(/^.{2}\s+/, "")
      path = status_and_path.include?("->") ? status_and_path.split("->").last.strip : status_and_path
      path.match(/\A"(.*)"\z/) ? Regexp.last_match(1) : path
    end.compact
  end

  def rubocop_target_paths(status_output)
    raw = status_output.nil? || status_output.strip.empty? ? `git status --porcelain --branch` : status_output
    porcelain_file_paths(raw).select do |path|
      RUBY_LINT_EXTENSIONS.include?(File.extname(path).downcase) && File.file?(path)
    end
  end
end
