# frozen_string_literal: true

require "open3"
require "shellwords"
require "colorize"

# Autocorrects changed Ruby sources with RuboCop before commit planning. Resolves each file to
# the nearest `.rubocop.yml` (Rails apps under a monorepo), then runs `bundle exec rubocop`
# or plain `rubocop` from that project root.
module GitCommitRubocop
  module_function

  RUBY_LINT_EXTENSIONS = %w[.rb .rake .gemspec].freeze
  BUNDLED_RUBOCOP_ARGV = %w[bundle exec rubocop].freeze
  PLAIN_RUBOCOP_ARGV = %w[rubocop].freeze
  PROBE_CONTENT = "\n".freeze

  # `launch_cwd` is where git_commit_gpt started (before chdir); used when Ruby files yield no
  # grouped root but the launcher cwd itself is a Ruby app with RuboCop.
  def autocorrect_before_plan!(status_output, launch_cwd: nil)
    git_root = git_repository_root
    return if git_root.nil?

    ruby_abs_paths = absolute_ruby_file_paths(status_output, git_root)
    return if ruby_abs_paths.empty?

    groups = build_rubocop_groups(ruby_abs_paths, launch_cwd)
    rubocop_autocorrect_each_group(groups)
  end

  def project_rubocop_enabled?(start_directory = Dir.pwd)
    walk_up_has_rubocop_yml?(File.expand_path(start_directory))
  end

  def rubocop_available?(start_directory = Dir.pwd)
    root = nearest_rubocop_config_directory(File.expand_path(start_directory))
    return false unless root

    !rubocop_argv_for_root(root).nil?
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
    git_root = git_repository_root
    return [] if git_root.nil?

    raw = porcelain_raw_or_fallback(status_output)
    collect_git_relative_ruby_paths(raw, git_root)
  end

  def rubocop_argv
    rubocop_argv_for_root(Dir.pwd)
  end

  def rubocop_argv_for_root(rubocop_project_root)
    return nil if rubocop_project_root.nil?

    @rubocop_argv_cache ||= {}
    @rubocop_argv_cache.fetch(rubocop_project_root) do
      @rubocop_argv_cache[rubocop_project_root] = resolve_rubocop_argv(rubocop_project_root)
    end
  end

  def git_repository_root
    out = `git rev-parse --show-toplevel 2>/dev/null`.strip
    $?.success? ? out : nil
  end

  def absolute_ruby_file_paths(status_output, git_root)
    raw = status_output.nil? || status_output.strip.empty? ? `git status --porcelain --branch` : status_output
    porcelain_file_paths(raw).filter_map do |rel|
      rel = rel.gsub("\\", "/")
      next nil if rel.end_with?("/")
      next nil unless RUBY_LINT_EXTENSIONS.include?(File.extname(rel).downcase)

      abs = File.expand_path(rel, git_root)
      next unless File.file?(abs)

      abs
    end.uniq
  end

  def group_absolute_paths_by_rubocop_root(absolute_paths)
    groups = Hash.new { |h, k| h[k] = [] }
    absolute_paths.each do |abs|
      root = nearest_rubocop_config_directory(abs)
      next unless root

      rel = descendant_relative_between(root, abs)
      groups[root] << rel
    end
    groups.each_value(&:uniq!)
    groups
  end

  def enrich_groups_from_launch_cwd!(groups, ruby_abs_paths, launch_cwd)
    return unless groups.empty?

    launch_proj = nearest_rubocop_config_directory(File.expand_path(launch_cwd))
    return if launch_proj.nil?
    return if rubocop_argv_for_root(launch_proj).nil?

    extras = ruby_abs_paths.filter_map do |abs|
      next unless abs.start_with?(File.join(launch_proj, ""))

      descendant_relative_between(launch_proj, abs)
    end.uniq
    merge_group!(groups, launch_proj, extras)
  end

  def merge_group!(groups, root, paths)
    return if paths.empty?

    groups[root] = (groups[root] + paths).uniq
  end

  def nearest_rubocop_config_directory(seed_path)
    path = File.directory?(seed_path) ? seed_path : File.dirname(seed_path)
    path = File.expand_path(path)
    loop do
      return path if rubocop_config_file_here?(path)

      parent = File.dirname(path)
      break if parent == path

      path = parent
    end
    nil
  end

  def rubocop_config_file_here?(dir)
    %w[.rubocop.yml .rubocop_todo.yml].any? { |name| File.file?(File.join(dir, name)) }
  end

  def walk_up_has_rubocop_yml?(start_directory)
    path = File.expand_path(start_directory)
    return true if File.file?(path) && rubocop_config_file_here?(File.dirname(path))

    loop do
      return true if rubocop_config_file_here?(path)

      parent = File.dirname(path)
      break if parent == path

      path = parent
    end
    false
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

  def build_rubocop_groups(ruby_abs_paths, launch_cwd)
    groups = group_absolute_paths_by_rubocop_root(ruby_abs_paths)
    enrich_groups_from_launch_cwd!(groups, ruby_abs_paths, launch_cwd) if launch_cwd && groups.empty?

    groups
  end

  def rubocop_autocorrect_each_group(groups)
    groups.each do |rubocop_root, rel_targets|
      argv = rubocop_argv_for_root(rubocop_root)
      next if argv.nil? || rel_targets.empty?

      cmd = Shellwords.shelljoin([*argv, "-a", "--", *rel_targets])
      puts "Running: #{cmd}".green
      Dir.chdir(rubocop_root) do
        next if run_rubocop(argv, "-a", "--", *rel_targets)

        warn "RuboCop reported offenses that remain after autocorrect; fix or exclude them manually.".red
        exit 1
      end
    end
  end

  def porcelain_raw_or_fallback(status_output)
    return `git status --porcelain --branch` if status_output.nil? || status_output.strip.empty?

    status_output
  end

  def collect_git_relative_ruby_paths(raw, git_root)
    porcelain_file_paths(raw).each_with_object([]) do |rel, acc|
      next unless RUBY_LINT_EXTENSIONS.include?(File.extname(rel).downcase)

      abs = File.expand_path(rel, git_root)
      next unless File.file?(abs)

      acc << descendant_relative_between(git_root, abs)
    end
  end

  def descendant_relative_between(ancestor_absolute, descendant_absolute)
    ancestor = File.expand_path(ancestor_absolute)
    descendant = File.expand_path(descendant_absolute)
    return "." if descendant == ancestor

    prefix = "#{ancestor}#{File::SEPARATOR}"
    unless descendant.start_with?(prefix)
      raise ArgumentError, "path #{descendant} not under #{ancestor}"
    end

    descendant.delete_prefix(prefix)
  end

  private_class_method :resolve_rubocop_argv, :rubocop_runs_here?, :rubocop_probe_capture, :plain_rubocop_argv?,
                       :without_bundler_env, :run_rubocop, :merge_group!, :enrich_groups_from_launch_cwd!,
                       :group_absolute_paths_by_rubocop_root, :absolute_ruby_file_paths, :git_repository_root,
                       :nearest_rubocop_config_directory, :rubocop_config_file_here?, :walk_up_has_rubocop_yml?,
                       :build_rubocop_groups, :rubocop_autocorrect_each_group, :porcelain_raw_or_fallback,
                       :collect_git_relative_ruby_paths, :descendant_relative_between
end
