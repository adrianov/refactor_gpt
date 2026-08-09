# frozen_string_literal: true

require "colorize"

# CLI flags for git_commit_gpt: --debug, --watch, --auto [0-100] (quiet), --push, plus free-text hint.
class GitCommitOptions
  DEFAULT_WARNING_LEVEL = 50

  Options = Struct.new(:debug, :watch, :auto, :warning_level, :push, :hint, keyword_init: true) do
    def allows_warnings?(warnings)
      Array(warnings).none? { |warning| score(warning) > warning_level }
    end

    def score(warning)
      prob = warning["probability"]
      return 100 if prob.nil?

      prob.to_f * 100
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
      warning_level: @warning_level, push: @push,
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
end
