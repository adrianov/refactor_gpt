# frozen_string_literal: true

# Transient network/resource failure that should be retried or fall back to OpenRouter.
class NetworkResourceError < StandardError
end
