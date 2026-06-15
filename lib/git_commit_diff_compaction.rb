# frozen_string_literal: true

require 'open3'

# Prepends repo-wide git diff --numstat -w, then per-path unified diffs (full → light → omit chunk).
# Paths reported as deleted-only (--diff-filter=D) skip unified diff text; numstat already states removal.
# Fits limit_chars (Ruby String character count, same unit as CommitPlanClient) by lowering tiers / omitting chunks.
# budget_omitted_paths: paths demoted to :omit to save space (not delete-only); no unified hunk in body.
class GitCommitDiffCompaction
  FULL_OPTS = %w[-w -W --no-prefix --histogram].freeze
  LIGHT_UNIFIED_OPTS = %w[-w --no-prefix].freeze
  PER_PATH_LIGHT_OPTS = LIGHT_UNIFIED_OPTS
  # Last resort when -w hides every hunk (whitespace-only edits); same shape without -w.
  NO_WS_FULL_OPTS = %w[-W --no-prefix --histogram].freeze
  NO_WS_LIGHT_OPTS = %w[--no-prefix].freeze

  DETAIL_SEPARATOR_CHARS = 2

  Result = Data.define(:body, :budget_omitted_paths)

  class << self
    # limit_chars comes from CommitPlanClient.diff_body_budgets_chars (single payload ceiling).
    def build(ref_spec:, limit_chars:)
      new(ref_spec: ref_spec, limit_chars: limit_chars).build
    end
  end

  def initialize(ref_spec:, limit_chars:)
    @ref_spec = ref_spec.to_s
    @limit_chars = limit_chars
    @tiers = {}
    @raw_by_path_tier = {}
    @detail_budget = 0
    @budget_omitted_paths = []
  end

  def build
    prefix = global_numstat_prefix
    @paths = changed_paths(@ref_spec)
    @detail_budget = [@limit_chars - prefix.length - DETAIL_SEPARATOR_CHARS, 0].max

    detailed = detailed_section_or_empty
    body = join_prefix_and_detail(prefix, detailed)
    body = whitespace_only_fallback_body if body.strip.empty? && !@paths.empty?
    Result.new(body: body, budget_omitted_paths: @budget_omitted_paths)
  end

  private

  def whitespace_only_fallback_body
    prefix = raw_numstat_prefix
    @detail_budget = [@limit_chars - prefix.length - DETAIL_SEPARATOR_CHARS, 0].max
    join_prefix_and_detail(prefix, bounded_detailed(non_deleted_tier: :no_ws_full, demote_pairs: no_ws_demote_pairs))
  end

  def raw_numstat_prefix
    numstat_prefix(
      ignore_whitespace: false,
      header_line: '(whitespace or formatting only: unified diff and numstat without -w)'
    )
  end

  def global_numstat_prefix
    numstat_prefix(ignore_whitespace: true)
  end

  def numstat_prefix(ignore_whitespace:, header_line: nil)
    cmd = %w[git diff --numstat]
    cmd << '-w' if ignore_whitespace
    cmd << @ref_spec
    out, _, st = Open3.capture3(*cmd)
    return '' unless st.success?

    stripped = utf8_safe(out).strip
    return '' if stripped.empty?

    flag = ignore_whitespace ? ' -w' : ''
    lines = []
    lines << header_line if header_line
    lines << "(all paths: git diff --numstat#{flag} #{@ref_spec})"
    "#{lines.join("\n")}\n#{stripped}\n"
  end

  def detailed_section_or_empty
    return '' if @paths.empty?

    bounded_detailed(non_deleted_tier: :full, demote_pairs: standard_demote_pairs)
  end

  def bounded_detailed(non_deleted_tier:, demote_pairs:)
    deleted = paths_deleted_only(@ref_spec)
    @tiers = @paths.to_h { |p| [p, deleted.include?(p) ? :omit : non_deleted_tier] }
    demote_pairs.each { |from_tier, to_tier| demote_tier_pool(from_tier, to_tier) }
    @budget_omitted_paths = @paths.select { |p| @tiers[p] == :omit && !deleted.include?(p) }
    assemble_detailed
  end

  def standard_demote_pairs
    [[:full, :light], [:light, :omit]]
  end

  def no_ws_demote_pairs
    [[:no_ws_full, :no_ws_light], [:no_ws_light, :omit]]
  end

  def changed_paths(ref_spec)
    out, _, st = Open3.capture3('git', 'diff', '--name-only', '-z', ref_spec)
    return [] unless st.success?

    out.split("\0").reject(&:empty?)
  end

  def paths_deleted_only(ref_spec)
    out, _, st = Open3.capture3('git', 'diff', '--diff-filter=D', '--name-only', '-z', ref_spec)
    return Set.new unless st.success?

    out.split("\0").reject(&:empty?).to_set
  end

  def demote_tier_pool(from_tier, to_tier)
    loop do
      break if detailed_chars <= @detail_budget

      pool = @paths.select { |p| @tiers[p] == from_tier }
      break if pool.empty?

      victim = pool.max_by { |p| victim_priority(p, from_tier, to_tier) }
      @tiers[victim] = to_tier
    end
  end

  def detailed_chars
    assemble_detailed.length
  end

  def diff_chunk_chars(path, tier)
    raw_diff_chunk(path, tier).length
  end

  # Prefer demoting paths where stepping to the next tier removes the most characters from
  # the assembled detail (full→light: saved = full minus light). Tie-break on larger chunk at current tier.
  def victim_priority(path, from_tier, to_tier)
    shrink = chars_saved_demoting(path, from_tier, to_tier)
    current = diff_chunk_chars(path, from_tier)
    [shrink, current]
  end

  def chars_saved_demoting(path, from_tier, to_tier)
    return diff_chunk_chars(path, from_tier) if to_tier == :omit

    diff_chunk_chars(path, from_tier) - diff_chunk_chars(path, to_tier)
  end

  def assemble_detailed
    @paths.each_with_object(String.new) do |path, acc|
      next if @tiers[path] == :omit

      chunk = raw_diff_chunk(path, @tiers[path])
      next if chunk.strip.empty?

      acc << "\n\n" unless acc.empty?
      acc << chunk
    end
  end

  def raw_diff_chunk(path, tier)
    return '' if tier == :omit

    key = [path, tier]
    return @raw_by_path_tier[key] if @raw_by_path_tier.key?(key)

    @raw_by_path_tier[key] = capture_raw_diff(path, tier)
  end

  def capture_raw_diff(path, tier)
    opts = tier_opts(tier)
    out, _, st = Open3.capture3('git', 'diff', *opts, @ref_spec, '--', path)
    return '' unless st.success?

    utf8_safe(out)
  end

  def utf8_safe(str)
    s = str.to_s.dup.force_encoding(Encoding::UTF_8)
    s.valid_encoding? ? s : s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
  end

  def tier_opts(tier)
    case tier
    when :full then FULL_OPTS
    when :light then PER_PATH_LIGHT_OPTS
    when :no_ws_full then NO_WS_FULL_OPTS
    when :no_ws_light then NO_WS_LIGHT_OPTS
    else FULL_OPTS
    end
  end

  def join_prefix_and_detail(prefix, detailed)
    d = detailed.to_s.strip
    pfx = prefix.to_s.strip

    return prefix if d.empty?
    return detailed if pfx.empty?

    "#{prefix}\n\n#{detailed}"
  end
end
