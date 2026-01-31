# frozen_string_literal: true

# Renders done-requests recap (completed/failed) to the display. Extracted to keep Display under length limit.
class OutcomeDisplay
  def initialize(display)
    @display = display
  end

  def display_done_requests_recap(outcomes)
    return if outcomes.nil? || outcomes.empty?

    print_outcome_section('Completed', :green, outcomes.select { |o| o[:success] }.map { |o| o[:request] })
    print_outcome_section('Failed', :red, outcomes.reject { |o| o[:success] }.map { |o| o[:request] })
    @display.out_puts ''
  end

  private

  def print_outcome_section(label, color, items)
    return if items.empty?

    @display.puts "#{label} (#{items.size}):".send(color)
    items.each_with_index do |r, i|
      preview = preview_request(r).sub(/\A\d+\.\s*/, '')
      @display.out_puts @display.body("  #{i + 1}. #{preview}")
    end
  end

  def preview_request(request)
    line = request.to_s.lines.first&.chomp.to_s
    line.length > 80 ? "#{line[0..80]}..." : line
  end
end
