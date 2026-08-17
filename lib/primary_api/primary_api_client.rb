# frozen_string_literal: true

# Shared mixins for OpenAI-compatible and Gemini primary API clients.
module PrimaryApiClient
  def self.included(base)
    base.include PrimaryApiBackoff
    base.include PrimaryApiHttpErrors
    base.include PrimaryApiFallback
    base.include ApiErrorDisplay
    base.include PrimaryApiProgress
  end

  def resolve_proxy_url
    PrimaryApiProxy.resolve(nil, @env_vars || load_env_vars)
  end
end
