# frozen_string_literal: true

# Thread-safe queue for requests entered while the agent is running.
# Combined into one message for the next agent run.
class PendingRequestQueue
  def initialize(display)
    @queue = []
    @mutex = Mutex.new
    @display = display
  end

  def add(request, current_request: nil)
    return if request.to_s.strip.empty?

    @mutex.synchronize do
      display_running_if_present(current_request)
      @queue << request.to_s.strip
      @display.puts "Queued (#{@queue.size}): #{request_preview(request)}".light_blue
    end
  end

  def size
    @mutex.synchronize { @queue.size }
  end

  def snapshot
    @mutex.synchronize { @queue.dup }
  end

  def take_all
    @mutex.synchronize do
      out = @queue.dup
      @queue.clear
      out
    end
  end

  def to_combined_request(requests)
    return nil if requests.nil? || requests.empty?

    requests.each_with_index.map { |r, i| "#{i + 1}. #{r}" }.join("\n\n")
  end

  private

  def display_running_if_present(current_request)
    return if current_request.to_s.strip.empty?

    @display.puts "Running: #{request_preview(current_request)}".cyan
  end

  def request_preview(text)
    return '' if text.to_s.strip.empty?

    preview = text.to_s.strip.lines.first&.chomp
    preview = preview[0..60] + '...' if preview && preview.length > 60
    preview || ''
  end
end
