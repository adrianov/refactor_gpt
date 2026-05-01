# frozen_string_literal: true

require 'open3'

# Aggregates per-path git diffs under a byte budget by lowering verbosity per file:
# full unified (-w -W --no-prefix --histogram), lighter unified (-w --no-prefix), then --numstat -w.
class GitCommitDiffCompaction
  FULL_OPTS = GitUnifiedWholeRepoDiff::FULL_OPTS
  PER_PATH_LIGHT_OPTS = GitUnifiedWholeRepoDiff::LIGHT_UNIFIED_OPTS
  NUMSTAT_OPTS = %w[--numstat -w].freeze

  # Keeps two diff streams plus status/hints near CommitPlanClient::MAX_CONTENT_SIZE_CHARS.
  DEFAULT_LIMIT_BYTES = 68 * 1024

  class << self
    def build(ref_spec:, limit_bytes: DEFAULT_LIMIT_BYTES)
      new(ref_spec: ref_spec, limit_bytes: limit_bytes).build
    end
  end

  def initialize(ref_spec:, limit_bytes:)
    @ref_spec = ref_spec.to_s
    @limit_bytes = limit_bytes
    @paths = changed_paths(@ref_spec)
    @tiers = @paths.to_h { |p| [p, :full] }
    @raw_by_path_tier = {}
  end

  def build
    return whole_repo_fallback if @paths.empty?

    demote_tier_pool(:full, :light)
    demote_tier_pool(:light, :numstat)
    body = assemble
    body = whole_repo_fallback if body.strip.empty?
    truncate(body)
  end

  private

  def changed_paths(ref_spec)
    out, _, st = Open3.capture3('git', 'diff', '--name-only', '-z', ref_spec)
    return [] unless st.success?

    out.split("\0").reject(&:empty?)
  end

  def whole_repo_fallback
    GitUnifiedWholeRepoDiff.capture(@ref_spec) || ''
  end

  def demote_tier_pool(from_tier, to_tier)
    loop do
      break if assemble.bytesize <= @limit_bytes

      pool = @paths.select { |p| @tiers[p] == from_tier }
      break if pool.empty?

      victim = pool.max_by { |p| diff_chunk_bytes(p, from_tier) }
      @tiers[victim] = to_tier
    end
  end

  def diff_chunk_bytes(path, tier)
    raw_diff_chunk(path, tier).bytesize
  end

  def assemble
    @paths.each_with_object(String.new) do |path, acc|
      chunk = format_chunk(path, @tiers[path])
      next if chunk.strip.empty?

      acc << "\n\n" unless acc.empty?
      acc << chunk
    end
  end

  def format_chunk(path, tier)
    decorate_chunk(path, tier, raw_diff_chunk(path, tier))
  end

  def raw_diff_chunk(path, tier)
    key = [path, tier]
    return @raw_by_path_tier[key] if @raw_by_path_tier.key?(key)

    @raw_by_path_tier[key] = capture_raw_diff(path, tier)
  end

  def capture_raw_diff(path, tier)
    opts = tier_opts(tier)
    out, _, st = Open3.capture3('git', 'diff', *opts, @ref_spec, '--', path)
    return '' unless st.success?

    out
  end

  def tier_opts(tier)
    case tier
    when :full then FULL_OPTS
    when :light then PER_PATH_LIGHT_OPTS
    when :numstat then NUMSTAT_OPTS
    else FULL_OPTS
    end
  end

  def decorate_chunk(path, tier, raw)
    return raw if tier != :numstat

    stripped = raw.strip
    return '' if stripped.empty?

    "# #{path} (git diff --numstat -w)\n#{stripped}\n"
  end

  def truncate(body)
    return body if body.bytesize <= @limit_bytes

    slice = body.byteslice(0, @limit_bytes)
    cut_at = slice.rindex("\n")
    trimmed = cut_at ? slice.byteslice(0, cut_at + 1) : slice
    "#{trimmed}\n\n... (aggregated diff truncated at #{@limit_bytes} byte budget)\n"
  end
end
