# frozen_string_literal: true

require 'oj'

# Detects tool result errors and builds stable keys for "same tool, same parameters".
# Used to support policies like: interrupt when the same tool call fails repeatedly.
module ToolOutcome
  def self.tool_result_error?(tool)
    return false unless tool.is_a?(Hash)
    return false unless (tool[:subtype] || tool['subtype']).to_s == 'completed'

    result = tool[:result] || tool['result']
    result_has_error_key?(result)
  end

  # True only when result has an error field with a truthy value (e.g. "message").
  # Treats error: null, error: false, and missing key as success to avoid false-positive interrupts.
  def self.result_has_error_key?(result)
    return false if result.nil?
    return error_value_truthy?(result) if result.is_a?(Hash)

    parsed = parse_result_string(result)
    parsed.is_a?(Hash) && error_value_truthy?(parsed)
  end

  def self.error_value_truthy?(hash)
    v = hash['error'] || hash[:error]
    !v.nil? && v != false
  end

  # Stable key for deduplication: same name + same arguments => same key.
  def self.invocation_key(tool)
    return nil unless tool.is_a?(Hash)

    name = (tool[:name] || tool['name']).to_s
    args = tool[:arguments] || tool['arguments']
    normalized = normalize_args(args)
    "#{name}\0#{normalized}"
  end

  def self.parse_result_string(value)
    str = value.to_s.strip
    return nil if str.empty?

    Oj.load(str, symbol_keys: false)
  rescue Oj::ParseError, JSON::ParserError
    nil
  end

  def self.normalize_args(args)
    return '' if args.nil?
    return args.to_s unless args.is_a?(Hash) || args.is_a?(Array)
    return args.map { |e| normalize_args(e) }.join("\t") if args.is_a?(Array)

    normalize_hash_args(args)
  end

  def self.normalize_hash_args(args)
    args.each_with_object([]) do |(k, v), out|
      next if %w[explanation toolCallId].include?(k.to_s)

      out << "#{k}=#{normalize_arg_value(v)}"
    end.sort.join("\t")
  end

  def self.normalize_arg_value(v)
    case v
    when Hash, Array then Oj.dump(v, mode: :compat)
    else v.to_s
    end
  end
end
