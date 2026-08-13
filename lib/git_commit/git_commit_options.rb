# frozen_string_literal: true

require "colorize"

# CLI flags for git_commit_gpt: --debug, --watch, --auto [0-100] (quiet, muted),
# --commit auto|yes|no (default auto), --push, plus free-text hint.
class GitCommitOptions
  DEFAULT_WARNING_LEVEL = 50
  DEFAULT_COMMIT = "auto"
  COMMIT_MODES = %w[auto yes no].freeze

  Options = Struct.new(:debug, :watch, :auto, :warning_level, :commit, :push, :hint, keyword_init: true) do
    def allows_warnings?(warnings)
      Array(warnings).none? { |warning| score(warning) > warning_level }
    end

    def score(warning)
      prob = warning["probability"]
      return 100 if prob.nil?

      prob.to_f * 100
    end

    def proceed_without_prompt?(warnings, quiet: false)
      case commit
      when "yes" then true
      when "no" then false
      else quiet ? allows_warnings?(warnings) : Array(warnings).empty?
      end
    end
  end

  def self.parse(args)
    new(args).parse
  end

  def initialize(args)
    @args = args
    @debug = false
    @watch = false
    @auto = false
    @warning_level = DEFAULT_WARNING_LEVEL
    @commit = DEFAULT_COMMIT
    @push = false
    @hint_parts = []
  end

  def parse
    i = 0
    while i < @args.length
      i = take(@args[i], i)
    end
    Options.new(
      debug: @debug, watch: @watch, auto: @auto,
      warning_level: @warning_level, commit: @commit, push: @push,
      hint: @hint_parts.join(" ").strip
    )
  end

  private

  def take(arg, index)
    case arg
    when "--debug" then flag(:@debug, index)
    when "--watch" then flag(:@watch, index)
    when "--push" then flag(:@push, index)
    when "--print" then index + 1
    when /\A--auto=(.+)\z/
      set_auto_level(Regexp.last_match(1))
      index + 1
    when "--auto" then take_auto(index)
    when /\A--commit=(.+)\z/
      set_commit(Regexp.last_match(1))
      index + 1
    when "--commit" then take_commit(index)
    else
      @hint_parts << arg
      index + 1
    end
  end

  def flag(ivar, index)
    instance_variable_set(ivar, true)
    index + 1
  end

  def take_auto(index)
    @auto = true
    next_arg = @args[index + 1]
    return index + 1 unless next_arg&.match?(/\A\d+\z/)

    set_auto_level(next_arg)
    index + 2
  end

  def set_auto_level(value)
    @auto = true
    @warning_level = Integer(value)
    return if (0..100).cover?(@warning_level)

    abort_level(value)
  rescue ArgumentError
    abort_level(value)
  end

  def abort_level(value)
    warn "Invalid --auto level #{value.inspect}; expected an integer 0-100.".red
    exit 1
  end

  def take_commit(index)
    set_commit(@args[index + 1])
    index + 2
  end

  def set_commit(value)
    mode = value.to_s.downcase
    abort_commit(value) unless COMMIT_MODES.include?(mode)

    @commit = mode
  end

  def abort_commit(value)
    warn "Invalid --commit #{value.inspect}; expected auto, yes, or no.".red
    exit 1
  end
end
