# frozen_string_literal: true

# Tracks consecutive errors per tool invocation key; returns :interrupt after threshold.
# Used by AgentExecutor to stop runs when the same tool+params fails repeatedly.
class SameToolErrorTracker
  DEFAULT_THRESHOLD = 3

  def initialize(threshold: DEFAULT_THRESHOLD)
    @threshold = threshold
    @counts = {}
  end

  # Records one completed tool call. Returns :interrupt when this key has failed >= threshold times.
  def record(invocation_key, error:)
    return :ok if invocation_key.nil?

    if error
      @counts[invocation_key] = (@counts[invocation_key] || 0) + 1
      return @counts[invocation_key] >= @threshold ? :interrupt : :ok
    end

    @counts[invocation_key] = 0
    :ok
  end

  def reset
    @counts.clear
  end
end
