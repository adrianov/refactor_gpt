# frozen_string_literal: true

# Unrecoverable primary API balance exhaustion (e.g. Z.AI code 1113).
# Do not retry; fall through to OpenRouter when configured.
class BalanceError < StandardError
  attr_reader :status, :raw_body

  def initialize(message = "Balance exhausted", status: 429, raw_body: nil)
    @status = status
    @raw_body = raw_body
    super(message)
  end
end
