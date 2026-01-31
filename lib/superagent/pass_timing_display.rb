# frozen_string_literal: true

# Renders pass/feature timing and recap to the display. Isolated so Display stays under length limit.
class PassTimingDisplay
  # Order phases ran: refactor at pass start, then implementation, then review, then optional fix.
  PHASE_EXECUTION_ORDER = %i[refactor_time implementation_time review_time fix_time total_time].freeze
  # Order of phase rows in output (matches run order).
  PHASE_DISPLAY_ORDER = PHASE_EXECUTION_ORDER
  LABELS = {
    implementation_time: "Implementation", review_time: "Review", fix_time: "Fix",
    refactor_time: "Refactor", total_time: "Total"
  }.freeze

  def initialize(display)
    @display = display
  end

  def display_pass_timing(pass_timing)
    return unless pass_timing

    @display.out_puts ''
    @display.puts "Pass #{pass_timing[:pass]} timing:".cyan
    PHASE_DISPLAY_ORDER.each do |k|
      color = (k == :total_time) ? :cyan : :light_blue
      display_timing_item(LABELS[k], pass_timing[k], color)
    end
    @display.out_puts ''
  end

  def display_feature_timing(pass_timings, feature_start_time)
    return unless feature_start_time && pass_timings && !pass_timings.empty?

    total_feature_time = Time.now - feature_start_time
    @display.out_puts ''
    @display.puts "Feature/Bugfix/Chore timing:".cyan
    PHASE_DISPLAY_ORDER.each { |k| display_feature_timing_row(k, pass_timings, total_feature_time) }
    @display.out_puts ''
  end

  def display_passes_recap(pass_timings)
    return unless pass_timings && !pass_timings.empty?

    @display.out_puts ''
    fix_count = pass_timings.count { |p| (p[:fix_time] || 0) > 0 }
    runs = pass_timings.size + fix_count
    @display.puts "This request: #{runs} runs, #{fix_count} fixes".cyan
    @display.out_puts ''
    @display.puts "Models used and timings:".cyan
    pass_timings.each { |pass| display_single_pass_recap(pass) }
    @display.out_puts ''
  end

  def display_single_pass_recap(pass)
    model = pass[:model] || 'unknown'
    pass_num = pass[:pass] || '?'
    @display.puts "  Pass #{pass_num}: #{model}".light_blue
    PHASE_DISPLAY_ORDER.each do |k|
      color = (k == :total_time) ? :cyan : :light_black
      display_pass_detail(LABELS[k], pass[k], color: color)
    end
  end

  def display_pass_detail(label, time, color: :light_black)
    return unless time && time > 0
    @display.puts "    #{label}: #{@display.format_duration(time)}".send(color)
  end

  private

  def display_feature_timing_row(key, pass_timings, total_feature_time)
    duration = (key == :total_time) ? total_feature_time : pass_timings.sum { |p| p[key] || 0 }
    color = (key == :total_time) ? :cyan : :light_blue
    @display.puts "  #{LABELS[key]}: #{@display.format_duration(duration)}".send(color)
  end

  def display_timing_item(label, time, color)
    return unless time
    @display.puts "  #{label}: #{@display.format_duration(time)}".send(color)
  end
end
