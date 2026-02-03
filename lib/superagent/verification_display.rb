# frozen_string_literal: true

# Renders verification result and result content to the display. Extracted to keep Display under length limit.
# Result section: content from NDJSON type=result field; preserves newlines.
class VerificationDisplay
  def initialize(display)
    @display = display
  end

  # result_content: from Superagent#current_recap_text (NDJSON type=result field when present).
  def display_verification_result(verified, desc, context = '', call_failed: false, raw_recap: nil)
    display_result_section(raw_recap) if verified && (raw_recap && !raw_recap.to_s.empty?)
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

  def display_result_section(result_content)
    text = result_content.to_s.strip
    return if text.empty?

    @display.out_puts ''
    @display.puts 'Result:'.cyan
    text.each_line { |line| @display.out_puts @display.body("  #{line.chomp}") }
    @display.out_puts ''
    $stdout.flush unless @display.output_paused
  end
end
