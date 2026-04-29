# frozen_string_literal: true

require "open3"
require "shellwords"
require "colorize"

# Autocorrects changed Ruby files with RuboCop before commit planning (when the repo
# uses RuboCop). Exits if offenses remain after autocorrect.
module GitCommitRubocop
  module_function

  RUBY_LINT_EXTENSIONS = %w[.rb .rake .gemspec].freeze
  BUNDLED_RUBOCOP_ARGV = %w[bundle exec rubocop].freeze
  PLAIN_RUBOCOP_ARGV = %w[rubocop].freeze
  PROBE_CONTENT = "\n".freeze

  # Runs RuboCop `-a` on changed Ruby sources; exits non-zero when offenses remain.
  # Prefers `bundle exec rubocop` when that works; otherwise plain `rubocop` (Ruby version
  # mismatch, broken bundle, or missing plugin gems only in the bundle).
  def autocorrect_before_plan!(status_output)
    return unless project_rubocop_enabled?

    paths = rubocop_target_paths(status_output)
    return if paths.empty?

    argv = rubocop_argv
    return if argv.nil?

    cmd = Shellwords.shelljoin([*argv, "-a", "--", *paths])
    puts "Running: #{cmd}".green
    return if run_rubocop(argv, "-a", "--", *paths)

    warn "RuboCop reported offenses that remain after autocorrect; fix or exclude them manually.".red
    exit 1
  end

  def project_rubocop_enabled?(root = Dir.pwd)
    %w[.rubocop.yml .rubocop_todo.yml].any? { |name| File.file?(File.join(root, name)) }
  end

  def rubocop_available?
    !rubocop_argv.nil?
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

  def rubocop_argv
    cwd = Dir.pwd
    @rubocop_argv_cache ||= {}
    @rubocop_argv_cache.fetch(cwd) do
      @rubocop_argv_cache[cwd] = resolve_rubocop_argv(cwd)
    end
  end

  def resolve_rubocop_argv(root)
    if File.file?(File.join(root, "Gemfile"))
      return BUNDLED_RUBOCOP_ARGV if rubocop_runs_here?(BUNDLED_RUBOCOP_ARGV, root)
    end

    PLAIN_RUBOCOP_ARGV if rubocop_runs_here?(PLAIN_RUBOCOP_ARGV, root)
  end

  def rubocop_runs_here?(argv, root)
    path = "#{root}/.rubocop_probe_#{$$}_#{rand(999_999_999)}.rb"
    Dir.chdir(root) do
      File.binwrite(path, PROBE_CONTENT)
      _combined, status = rubocop_probe_capture(argv, path)
      status.success?
    end
  ensure
    File.unlink(path) if path && File.file?(path)
  end

  def rubocop_probe_capture(argv, probe_path)
    full = argv + ["--fail-level", "F", "-f", "simple", "--", probe_path]
    return Open3.capture2e(*full) unless plain_rubocop_argv?(argv)

    without_bundler_env { Open3.capture2e(*full) }
  end

  def plain_rubocop_argv?(argv)
    argv == PLAIN_RUBOCOP_ARGV
  end

  def without_bundler_env
    return yield unless defined?(Bundler) && Bundler.respond_to?(:with_unbundled_env)

    Bundler.with_unbundled_env { yield }
  end

  def run_rubocop(argv, *rest)
    if plain_rubocop_argv?(argv)
      without_bundler_env { system(*argv, *rest) }
    else
      system(*argv, *rest)
    end
  end

  private_class_method :resolve_rubocop_argv, :rubocop_runs_here?, :rubocop_probe_capture, :plain_rubocop_argv?,
                       :without_bundler_env, :run_rubocop
end
