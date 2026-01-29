# frozen_string_literal: true

require 'tty-cursor'
require 'tty-screen'

# Splits the terminal: scrollable top region for agent output, fixed bottom for request input.
# Uses DECSTBM scroll region so agent output stays in the top pane.
class SplitPane
  INPUT_ROWS = 3
  CURSOR = TTY::Cursor

  def initialize
    @height = TTY::Screen.height
    @top_bottom = [@height - INPUT_ROWS, 2].max
    @output_row = 1
    @mutex = Mutex.new
    @enabled = false
  end

  def enable
    return unless $stdout.tty? && @height >= INPUT_ROWS + 2

    @enabled = true
    @output_row = 1
    $stdout.print "\e[1;#{@top_bottom}r"
    $stdout.print CURSOR.move_to(1, 1)
    draw_bottom_bar
    $stdout.flush
  end

  def disable
    return unless @enabled

    @enabled = false
    $stdout.print "\e[r"
    $stdout.flush
  end

  def enabled?
    @enabled
  end

  def with_output_row
    return yield unless @enabled

    @mutex.synchronize do
      $stdout.print CURSOR.move_to(@output_row, 1)
      $stdout.flush
      yield
    end
  end

  def advance_output_row(newlines)
    return unless @enabled

    @mutex.synchronize do
      @output_row += newlines
      @output_row = @top_bottom if @output_row > @top_bottom
    end
  end

  def move_to_input_row
    return unless @enabled

    @mutex.synchronize do
      $stdout.print CURSOR.move_to(@top_bottom + 1, 1)
      $stdout.print CURSOR.clear_line
      $stdout.flush
    end
  end

  def show_input_prompt
    return unless @enabled

    @mutex.synchronize do
      $stdout.print CURSOR.move_to(@top_bottom + 1, 1)
      $stdout.print CURSOR.clear_line
      $stdout.print 'Next request: '
      $stdout.flush
    end
  end

  def show_queued(count, preview)
    return unless @enabled

    @mutex.synchronize do
      $stdout.print CURSOR.move_to(@top_bottom + 2, 1)
      $stdout.print CURSOR.clear_line
      text = "Queued (#{count}): #{preview.to_s[0..60]}#{'...' if preview.to_s.length > 60}"
      $stdout.print text
      $stdout.flush
    end
  end

  def clear_queued_line
    return unless @enabled

    @mutex.synchronize do
      $stdout.print CURSOR.move_to(@top_bottom + 2, 1)
      $stdout.print CURSOR.clear_line
      $stdout.flush
    end
  end

  private

  def draw_bottom_bar
    $stdout.print CURSOR.move_to(@top_bottom + 1, 1)
    $stdout.print CURSOR.clear_line
    $stdout.print CURSOR.move_to(@top_bottom + 2, 1)
    $stdout.print CURSOR.clear_line
    $stdout.print CURSOR.move_to(@top_bottom + 1, 1)
  end
end
