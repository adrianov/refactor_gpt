# frozen_string_literal: true

# Raised for HTTP 5xx from the primary API.
class ServerError < StandardError
  attr_reader :status, :raw_body

  def initialize(message = "Server error", status: 500, raw_body: nil)
    @status = status
    @raw_body = raw_body
    super(message)
  end
end
