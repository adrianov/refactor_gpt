# frozen_string_literal: true

# Renders verification result and full recap to the display. Extracted to keep Display under length limit.
class VerificationDisplay
  SUMMARY_MARKER = /^\s*Summary of changes\s*:?\s*$/i

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
      desc.each_line { |line| @display.out_puts @display.body("  #{line.chomp}") }
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
    lines = text.to_s.each_line.to_a
    summary_idx = lines.index { |l| l =~ SUMMARY_MARKER }
    print_recap_intro(lines, summary_idx)
    print_recap_summary(lines, summary_idx) if summary_idx
    @display.out_puts ''
    $stdout.flush unless @display.output_paused
  end

  def print_recap_intro(lines, summary_idx)
    range = summary_idx ? lines[0...summary_idx] : lines
    range.each { |line| @display.out_puts @display.body("  #{line.chomp}") unless line.chomp.empty? }
  end

  def print_recap_summary(lines, summary_idx)
    lines[summary_idx..].each { |line| @display.out_puts @display.body("  #{line.chomp}") }
  end
end
