# frozen_string_literal: true

# Renders verification result and full recap to the display. Extracted to keep Display under length limit.
# Recap is split into intro (lines before summary marker) and summary (marker to end); layout is in display_full_recap.
class VerificationDisplay
  RECAP_INDENT = '  '

  def initialize(display)
    @display = display
  end

  def display_verification_result(verified, desc, context = '', call_failed: false, full_recap: nil)
    display_full_recap(full_recap) if verified && full_recap.to_s.strip != ''
    prefix = verification_prefix(verified, call_failed)
    suffix = context.empty? ? '' : " #{context}"
    render_verification_message(prefix, suffix, desc, verified, context)
  end

  private

  def verification_prefix(verified, call_failed)
    return 'Verification call did not complete' if call_failed
    verified ? '✔ Passed' : '✗ Failed'
  end

  def render_verification_message(prefix, suffix, desc, verified, context)
    if desc && !desc.empty?
      @display.puts "#{prefix}#{suffix}:".send(verified ? :green : :yellow)
      desc.each_line { |line| @display.out_puts @display.body("#{RECAP_INDENT}#{line.chomp}") }
    elsif verified
      @display.puts "#{prefix}#{suffix}! Success.".send(:green)
    else
      @display.puts "#{prefix}#{suffix}! #{context.empty? ? 'Retrying...' : 'Next...'}".send(:yellow)
    end
  end

  def display_full_recap(text)
    return if text.to_s.strip == ''

    @display.out_puts ''
    @display.puts 'Full recap:'.cyan
    intro_lines, summary_lines = RecapFormatter.parse_recap_sections(text.to_s)
    print_recap_lines(intro_lines, skip_empty: true, blank_after_each: false)
    if summary_lines
      @display.out_puts ''
      print_recap_lines(summary_lines, skip_empty: false)
    end
    @display.out_puts ''
    $stdout.flush unless @display.output_paused
  end

  def print_recap_lines(lines, skip_empty: false, blank_after_each: false)
    lines.each do |line|
      next if skip_empty && line.empty?
      @display.out_puts @display.body("#{RECAP_INDENT}#{line}")
      @display.out_puts '' if blank_after_each
    end
  end
end
