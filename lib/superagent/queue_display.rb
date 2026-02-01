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
    requests.each_with_index { |r, i| @display.out_puts @display.body("  #{i + 1}. #{r.lines.first&.chomp}") }
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

  def print_running_preview(current_request)
    return if current_request.to_s.strip.empty?
    @display.puts "Running: #{pending_request_preview(current_request)}".cyan
  end
end
