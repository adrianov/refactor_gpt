# frozen_string_literal: true

# Renders verification result and full recap to the display. Extracted to keep Display under length limit.
# Recap layout: intro and summary preserve LLM newlines; no extra blank after each intro line.
class VerificationDisplay
  def initialize(display)
    @display = display
  end

  # raw_recap: raw agent output from Superagent#current_recap_text; do not compact.
  def display_verification_result(verified, desc, context = '', call_failed: false, raw_recap: nil)
    display_full_recap(raw_recap) if verified && (raw_recap && !raw_recap.to_s.strip.empty?)
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

  # raw_recap: same as display_verification_result (Superagent#current_recap_text; do not compact).
  def display_full_recap(raw_recap)
    text = RecapFormatter.prepare_recap_for_display(raw_recap)
    return if text.nil? || text.to_s.strip.empty?

    @display.out_puts ''
    @display.puts 'Full recap:'.cyan
    sections = RecapFormatter.parse_recap_sections(text)
    print_recap_lines(sections.intro_lines)
    summary = RecapFormatter.summary_block_from_text(text)
    print_summary_raw(summary) if summary
    @display.out_puts ''
    $stdout.flush unless @display.output_paused
  end

  def print_summary_raw(raw)
    @display.out_puts ''
    raw.each_line { |line| @display.out_puts @display.body("  #{line.chomp}") }
  end

  def print_recap_lines(lines)
    lines.each do |line|
      if line.empty?
        @display.out_puts ''
      else
        @display.out_puts @display.body("  #{line}")
      end
    end
  end
end
