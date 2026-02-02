# frozen_string_literal: true

require 'digest'

# Assigns permanent Excel-style session IDs (e.g. A1, B1). Letter = order of first appearance (A, B, C…).
# Digit = 1 (reserved for future use: distinctiveness or difficulty). IDs are persisted via
# read_index/persist_index so the same description always gets the same ID. Used by SessionTracker.
class SessionIdRegistry
  def initialize(read_index:, persist_index:)
    @read_index = read_index
    @persist_index = persist_index
    @description_letter_index = nil
  end

  def description_to_session_id(description)
    return nil if description.nil? || description.to_s.strip.empty?

    ensure_loaded
    key = description_key(description)
    idx = @description_letter_index.index(key)
    if idx.nil?
      @description_letter_index << key
      @persist_index.call(@description_letter_index)
      idx = @description_letter_index.size - 1
    end
    "#{index_to_excel_letter(idx)}1"
  end

  def descriptions_match(a, b)
    return false if a.nil? && b.nil?
    return a.to_s.strip == b.to_s.strip if a.nil? || b.nil?

    description_key(a) == description_key(b)
  end

  def description_letter_index
    @description_letter_index.is_a?(Array) ? @description_letter_index.dup : []
  end

  def load_index(arr)
    @description_letter_index = arr.is_a?(Array) ? arr.dup : []
  end

  private

  def description_key(description)
    normalized = description.to_s.downcase.strip
    Digest::SHA256.hexdigest(normalized)[0..15]
  end

  def ensure_loaded
    return if @description_letter_index.is_a?(Array)

    loaded = @read_index.call
    @description_letter_index = loaded.is_a?(Array) ? loaded.dup : []
  end

  def index_to_excel_letter(idx)
    return 'A' if idx < 0

    s = ''
    while idx >= 0
      s = (idx % 26 + 'A'.ord).chr + s
      idx = idx / 26 - 1
    end
    s
  end
end
