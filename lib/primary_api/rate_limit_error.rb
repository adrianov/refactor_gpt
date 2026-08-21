# frozen_string_literal: true

# Raised for recoverable rate limits (HTTP 429, or OpenRouter 400 wrapping upstream 429).
# Not for balance exhaustion — that prints and exits via PrimaryApiHttpErrors.
class RateLimitError < StandardError
  attr_reader :retry_after, :raw_body

  def initialize(message = "Rate limited", retry_after: nil, raw_body: nil)
    @retry_after = retry_after
    @raw_body = raw_body
    super(message)
  end
end
