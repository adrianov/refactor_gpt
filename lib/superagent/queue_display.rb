# frozen_string_literal: true

# Renders pending-queue list and running preview. Extracted to keep Display under length limit.
class QueueDisplay
  def initialize(display)
    @display = display
  end

  def display_pending_list(requests, current_request: nil)
    print_running_preview(current_request)
    return if requests.nil? || requests.empty?

    @display.puts "Using #{requests.size} queued request(s):".cyan
    requests.each_with_index { |r, i| pending_lines(r, i).each { |line| @display.out_puts @display.body(line) } }
    @display.out_puts ''
  end

  def pending_request_preview(text)
    RequestHistoryFormatter.queue_preview(text)
  end

  def display_session_type(continuation, tags)
    if continuation
      tag_display = tags.empty? ? '' : " [#{tags.join(', ')}]"
      @display.puts "↻ Continuing previous session#{tag_display}".light_blue
      @display.puts 'Step: Resuming previous session'.cyan
      @display.out_puts ''
    elsif tags.any?
      @display.puts "🆕 New session [#{tags.join(', ')}]".light_blue
      @display.out_puts ''
    end
  end

  private

  def pending_lines(item, index)
    text = (item.is_a?(Hash) ? (item[:text] || item[:request]) : item).to_s
    lines = text.lines.map(&:chomp).reject(&:empty?)
    return [] if lines.empty?

    first = "  #{index + 1}. #{lines.first}"
    rest = lines.drop(1).map { |l| "     #{l}" }
    [first] + rest
  end

  def print_running_preview(current_request)
    return if current_request.nil? || current_request.to_s.strip.empty?
    @display.puts "Running: #{pending_request_preview(current_request)}".cyan
  end
end
