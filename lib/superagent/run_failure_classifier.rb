# frozen_string_literal: true

# Classifies agent run failures as recoverable (retry) or unrecoverable.
module RunFailureClassifier
  UNRECOVERABLE_PHRASES = %w[503 502 404].freeze
  UNRECOVERABLE_MODEL_PHRASES = %w[not found not available unavailable invalid].freeze

  module_function

  def retryable_error?(output)
    return false if output.to_s.empty?

    output.match?(/CANCEL|canceled|stream closed|0x8|http\/2 stream closed|Connection stalled/i)
  end

  def stream_json_init?(output)
    return false if output.nil? || output.to_s.strip.empty?

    s = output.to_s.strip
    return true if s.start_with?('{') && s.include?('"type"') && s.include?('"system"')

    false
  end

  def unrecoverable_error?(output)
    return false if output.to_s.empty?

    n = output.to_s.downcase
    unrecoverable_phrase?(n) || unrecoverable_model?(n) || unrecoverable_usage?(n)
  end

  def usage_unrecoverable?(output)
    return false if output.to_s.empty?

    unrecoverable_usage?(output.to_s.downcase)
  end

  def failure_reason(output, status, stdout, timeout_reason)
    return :unrecoverable if unrecoverable_error?(output)
    return :recoverable if failure_reason_recoverable?(output, status, stdout, timeout_reason)
  end

  def unrecoverable_phrase?(n)
    UNRECOVERABLE_PHRASES.any? { |p| n.include?(p) } ||
      (n.include?('rate limit') && n.include?('exceeded')) ||
      n.include?('cannot use this model') ||
      n.include?('this error is unrecoverable')
  end

  def unrecoverable_model?(n)
    n.include?('model') && UNRECOVERABLE_MODEL_PHRASES.any? { |p| n.include?(p) }
  end

  def unrecoverable_usage?(n)
    (n.include?('rate limit') && n.include?('exceeded')) ||
      n.include?('usage limit') ||
      n.include?('this error is unrecoverable')
  end

  def failure_reason_recoverable?(output, status, stdout, timeout_reason)
    (output.nil? || output.to_s.strip.empty?) ||
      timeout_reason == :no_data ||
      ((status.nil? || !status.success?) && stdout.nil?) ||
      stream_json_init?(output) ||
      retryable_error?(output) ||
      output.to_s.include?('Timeout after')
  end
end
