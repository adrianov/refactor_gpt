# frozen_string_literal: true

# Compatibility shim: faraday-typhoeus invokes Faraday's streaming +on_data+
# callback with (chunk, size), while ruby-llm's Faraday 2 handler expects
# (chunk, size, env). Without this, every SSE chunk is dropped when the
# typhoeus adapter is selected and streamed answers come back empty.
module TyphoeusStreamingCompat
  NO_ENV = Object.new.freeze

  module_function

  # Installs the shim once on ruby-llm's Faraday 2 handler factory.
  # module_function methods resolve through the singleton class, so the shim
  # must be prepended there rather than on the module itself.
  def apply
    target = RubyLLM::Streaming::FaradayHandlers.singleton_class
    return if target.include?(self)

    target.prepend(self)
  end

  # Same routing as ruby-llm's v2_on_data, tolerating two-arg invocation.
  def v2_on_data(on_chunk, on_failed_response)
    proc do |chunk, _bytes, env = NO_ENV|
      if env == NO_ENV
        on_chunk.call(chunk, nil)
      elsif env&.status == 200
        on_chunk.call(chunk, env)
      else
        on_failed_response.call(chunk, env)
      end
    end
  end
end
