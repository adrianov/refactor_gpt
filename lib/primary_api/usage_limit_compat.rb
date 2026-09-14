# frozen_string_literal: true

require 'ruby_llm/error_middleware'

# Quota/usage-limit failures (e.g. "Usage limit reached for 5 hour. Your limit will reset at ...")
# state a provider-side reset time far in the future, so retrying within seconds can never succeed.
# ruby-llm's transport retries RateLimitError three times, so this shim re-raises matching error
# bodies as a dedicated error class the transport retry list does not match, surfacing the failure
# immediately; the reset time shown to the user derives from the response's retry-after hint
# (when requests may actually resume), not the message's far-off window-reset timestamp.
module UsageLimitCompat
  # Deliberately not a RubyLLM::RateLimitError subclass: the transport retry list matches by
  # ancestry, so staying outside it is what keeps this error unretried.
  class UsageLimitError < RubyLLM::Error
    def retry_after_seconds
      UsageLimitCompat.retry_after_seconds(response)
    end
  end

  # Response header names that state a cooldown, with their unit in seconds.
  RETRY_AFTER_HEADERS = [['retry-after-ms', 0.001], ['retry-after', 1]].freeze

  USAGE_LIMIT_PATTERNS = [
    /usage limit/i,
    /limit will reset at/i,
    /insufficient quota/i,
    /quota exceeded/i,
    /exceeded your (?:current )?quota/i
  ].freeze

  def self.apply
    target = RubyLLM::ErrorMiddleware.singleton_class
    return if target.include?(self)

    target.prepend(self)
  end

  def self.usage_limit?(body)
    text = body.to_s
    return false if text.strip.empty?

    USAGE_LIMIT_PATTERNS.any? { |pattern| text.match?(pattern) }
  end

  def self.error_status?(response)
    response.respond_to?(:status) && response.status.to_i >= 400
  end

  def self.message_from(provider, response)
    provider_message = provider&.parse_error(response).to_s.strip
    provider_message.empty? ? response.body.to_s : provider_message
  end

  # The retry-after hint beats the message's "will reset at" timestamp: the header tracks when
  # requests may resume, while the embedded window-reset time can sit hours away.
  def self.retry_after_seconds(response)
    headers = response.respond_to?(:headers) ? response.headers : nil
    return unless headers

    RETRY_AFTER_HEADERS.each do |name, unit_seconds|
      seconds = headers[name].to_f * unit_seconds
      return seconds if seconds.positive?
    end
    nil
  end

  # Prepended onto RubyLLM::ErrorMiddleware; must stay a public instance method so explicit
  # receiver calls (ErrorMiddleware.parse_error) resolve through the singleton chain.
  def parse_error(provider:, response:)
    return super unless UsageLimitCompat.error_status?(response) && UsageLimitCompat.usage_limit?(response.body)

    raise UsageLimitError.new(response, UsageLimitCompat.message_from(provider, response))
  end
end
