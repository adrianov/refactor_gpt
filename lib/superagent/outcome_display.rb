# frozen_string_literal: true

# Renders done-requests recap (completed/failed, and optionally queued) to the display.
# Sections share the same layout; adding a section (e.g. Queued) is one entry in outcome_sections.
class OutcomeDisplay
  def initialize(display)
    @display = display
  end

  def display_done_requests_recap(outcomes, queued: nil)
    outcomes = outcomes || []
    return if outcomes.empty? && (queued.nil? || queued.empty?)

    outcome_sections(outcomes, queued).each { |s| print_outcome_section(s[:label], s[:color], s[:items]) }
    @display.out_puts ''
  end

  private

  def outcome_sections(outcomes, queued)
    completed = outcomes.select { |o| o[:success] }.map { |o| o[:request] }
    failed = outcomes.reject { |o| o[:success] }.map { |o| o[:request] }
    sections = [
      { label: 'Completed', color: :green, items: completed },
      { label: 'Failed', color: :red, items: failed }
    ]
    sections << { label: 'Queued', color: :light_blue, items: queued } if queued&.any?
    sections
  end

  def print_outcome_section(label, color, items)
    return if items.empty?

    @display.puts "#{label} (#{items.size}):".send(color)
    items.each_with_index do |r, i|
      preview = RequestHistoryFormatter.recap_preview(r).sub(/\A\d+\.\s*/, '')
      @display.out_puts @display.body("  #{i + 1}. #{preview}")
    end
  end
end
