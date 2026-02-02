# frozen_string_literal: true

# Thread-safe queue for requests entered while the agent is running.
# Items store text plus session classification (description, session_id) so same-session requests can be merged.
class PendingRequestQueue
  def initialize(display)
    @queue = []
    @mutex = Mutex.new
    @display = display
  end

  # Adds a request. With analysis/session_id, item is classified for merging by session when drained.
  def add(request, analysis: nil, session_id: nil)
    text = request.is_a?(Hash) ? (request[:text] || request[:request]).to_s : request.to_s
    return if text.strip.empty?

    text = RequestPreparer.normalized_request_text(text)
    item = item_from(text, analysis, session_id)
    @mutex.synchronize do
      @queue << item
      @display.puts "Queued (#{@queue.size}): #{request_preview(item)}".light_blue
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

  # Groups items by session_id (nil = each item its own group), merges each group into one text with bullet points.
  # Returns array of { text:, description:, session_id:, tags:, continuation: } for execute_new_request.
  def to_merged_requests_by_session(items)
    return [] if items.nil? || items.empty?

    groups = group_by_session(items)
    groups.map { |_sid, list| merge_group(list) }
  end

  # Prepends merged requests (same shape as to_merged_requests_by_session) so they run after current run.
  def prepend_merged(merged_list)
    return if merged_list.nil? || merged_list.empty?

    list = Array(merged_list).map { |m| m.is_a?(Hash) ? m : { text: m.to_s, description: nil, session_id: nil } }
    @mutex.synchronize { list.reverse_each { |m| @queue.unshift(m) } }
  end

  def to_combined_request(requests)
    return nil if requests.nil? || requests.empty?

    requests.each_with_index.map { |r, i| "#{i + 1}. #{item_text(r)}" }.join("\n\n")
  end

  private

  def item_from(text, analysis, session_id)
    {
      text: text,
      description: analysis&.dig(:description),
      session_id: session_id,
      tags: analysis&.dig(:tags) || [],
      continuation: analysis&.dig(:continuation)
    }
  end

  def item_text(item)
    item.is_a?(Hash) ? (item[:text] || item[:request]).to_s : item.to_s
  end

  def request_preview(item)
    RequestHistoryFormatter.queue_preview(item_text(item))
  end

  def group_by_session(items)
    items.group_by do |item|
      sid = item.is_a?(Hash) ? item[:session_id] : nil
      sid.nil? ? object_id_for(item) : sid
    end
  end

  def object_id_for(item)
    # Unclassified items each get their own group so they are not merged.
    "u#{item.object_id}"
  end

  def merge_group(list)
    texts = list.map { |item| item_text(item).strip }.reject(&:empty?)
    merged = texts.map { |t| "• #{t}" }.join("\n")
    first = list.first
    first_hash = first.is_a?(Hash) ? first : {}
    {
      text: merged,
      description: first_hash[:description],
      session_id: first_hash[:session_id],
      tags: first_hash[:tags] || [],
      continuation: first_hash[:continuation]
    }
  end
end
