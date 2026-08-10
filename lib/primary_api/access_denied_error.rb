# frozen_string_literal: true

# Primary API HTTP 403 (e.g. OpenRouter security policy). Do not retry; fall through to an alternate provider.
class AccessDeniedError < StandardError
  attr_reader :status, :raw_body

  def initialize(message = 'Access denied', status: 403, raw_body: nil)
    @status = status
    @raw_body = raw_body
    super(message)
  end
end
