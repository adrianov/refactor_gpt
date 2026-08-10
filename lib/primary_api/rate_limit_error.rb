# frozen_string_literal: true

# Raised for recoverable HTTP 429 rate limits (not balance exhaustion — see BalanceError).
class RateLimitError < StandardError
  attr_reader :retry_after, :raw_body

  def initialize(message = "Rate limited", retry_after: nil, raw_body: nil)
    @retry_after = retry_after
    @raw_body = raw_body
    super(message)
  end
end
