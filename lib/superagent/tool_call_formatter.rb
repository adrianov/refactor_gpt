# frozen_string_literal: true

# Formats tool call arguments for display (hash/string truncation, URLs, paths).
class ToolCallFormatter
  def format_args(args)
    return nil unless args
    return format_hash_args(args) if args.is_a?(Hash)
    return format_string_args(args) if args.is_a?(String) && !args.empty?

    nil
  end

  private

  def format_hash_args(args)
    filtered_args = args.reject { |k, _| %w[explanation toolCallId].include?(k) }
    return nil if filtered_args.empty?

    formatted_parts = filtered_args.map { |k, v| "#{k}: #{format_arg_value(v)}" }
    truncate_string(formatted_parts.join(', '), 120)
  end

  def format_string_args(args)
    truncate_string(args, 120)
  end

  def truncate_string(str, max_length)
    return str if str.length <= max_length
    "#{str[0..(max_length - 4)]}..."
  end

  def format_arg_value(v)
    case v
    when String then format_string_value(v)
    when Hash, Array then format_inspect_value(v)
    else v.inspect
    end
  end

  def format_string_value(v)
    return v if v.length <= 50
    return format_url_value(v) if v.match?(%r{\Ahttps?://})
    return format_path_value(v) if v.include?('/') && v.length > 40

    "#{v[0..47]}..."
  end

  def format_url_value(v)
    m = v.match(%r{\A(https?://[^/]+)(/.*)?\z})
    return v if !m || v.length <= 80

    origin = m[1]
    path = m[2]
    return origin if path.nil? || path.empty?
    return v if (origin.length + path.length) <= 80

    "#{origin}/...#{url_path_suffix(path)}"
  end

  def url_path_suffix(path)
    filename = path.split('/').last
    return '' if filename.nil? || filename.empty?
    filename.length > 30 ? filename[-27..] : filename
  end

  def format_path_value(v)
    parts = v.split('/')
    filename = parts.last
    return "#{parts[0..-2].join('/')}/...#{filename[-27..-1]}" if filename.length > 30
    return "#{parts[0]}/...#{parts[-2]}/#{filename}" if parts.length > 3

    v.length > 50 ? "#{v[0..47]}..." : v
  end

  def format_inspect_value(v)
    inspected = v.inspect
    inspected.length > 50 ? "#{inspected[0..47]}..." : inspected
  end
end
