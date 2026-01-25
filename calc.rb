# frozen_string_literal: true

begin
  require 'reline'
  RELINE_AVAILABLE = true
rescue LoadError
  RELINE_AVAILABLE = false
end

# Basic calculator that performs arithmetic operations and evaluates formulas
class Calculator
  MAX_FORMULA_LENGTH = 1000
  MAX_EXPONENT = 1000
  MAX_NESTING_DEPTH = 50

  def add(a, b)
    a + b
  end

  def subtract(a, b)
    a - b
  end

  def multiply(a, b)
    a * b
  end

  def divide(a, b)
    raise ArgumentError, 'Cannot divide by zero' if b.zero?

    a.to_f / b
  end

  def power(a, b)
    raise ArgumentError, "Exponent too large (max #{MAX_EXPONENT})" if b.abs > MAX_EXPONENT

    a**b
  end

  def modulo(a, b)
    raise ArgumentError, 'Cannot modulo by zero' if b.zero?

    a % b
  end

  def evaluate(formula, last_result: nil)
    formula = normalize_formula(formula)
    validate_formula_length(formula)
    formula = substitute_last_result(formula, last_result)
    raise ArgumentError, 'Empty formula' if formula.empty?

    validate_nesting_depth(formula)
    tokens = tokenize(formula)
    evaluate_tokens(tokens)
  end

  private

  def normalize_formula(formula)
    formula.strip.gsub(/\s+/, '')
  end

  def validate_formula_length(formula)
    return if formula.length <= MAX_FORMULA_LENGTH

    raise ArgumentError, "Formula too long (max #{MAX_FORMULA_LENGTH} characters)"
  end

  def validate_nesting_depth(formula)
    depth = 0
    max_depth = 0

    formula.each_char do |char|
      if char == '('
        depth += 1
        max_depth = depth if depth > max_depth
      elsif char == ')'
        depth -= 1
      end
    end

    return if max_depth <= MAX_NESTING_DEPTH

    raise ArgumentError, "Nesting too deep (max #{MAX_NESTING_DEPTH} levels)"
  end

  def substitute_last_result(formula, last_result)
    return formula unless formula.match?(/\b(ans|_)\b/i)
    raise ArgumentError, 'No previous result available' if last_result.nil?

    formula.gsub(/\b(ans|_)\b/i, last_result.to_s)
  end

  def tokenize(formula)
    tokens = []
    current_number = ''
    i = 0

    while i < formula.length
      char = formula[i]

      if digit_or_decimal?(char)
        current_number += char
      elsif char == '(' || char == ')'
        flush_number(tokens, current_number)
        tokens << char
        current_number = ''
      elsif operator_except_minus?(char)
        flush_number(tokens, current_number)
        tokens << char
        current_number = ''
      elsif char == '-'
        handle_minus(tokens, current_number, char)
        current_number = ''
      else
        raise ArgumentError, "Invalid character: '#{char}'"
      end

      i += 1
    end

    flush_number(tokens, current_number)
    tokens
  end

  def digit_or_decimal?(char)
    (char >= '0' && char <= '9') || char == '.'
  end

  def operator_except_minus?(char)
    char == '+' || char == '*' || char == '/' || char == '%' || char == '^'
  end

  def flush_number(tokens, number)
    return if number.empty?

    validate_number_format(number)
    tokens << Float(number)
  rescue ArgumentError => e
    raise ArgumentError, "Invalid number format: '#{number}' - #{e.message}"
  end

  def validate_number_format(number)
    raise ArgumentError, 'Too many decimal points' if number.count('.') > 1
    raise ArgumentError, 'Invalid number' if number.start_with?('.') && number.length == 1
  end

  def handle_minus(tokens, current_number, char)
    flush_number(tokens, current_number)

    tokens << 0.0 if unary_minus_context?(tokens)

    tokens << char
  end

  def unary_minus_context?(tokens)
    tokens.empty? || %w[( + - * / % ^].include?(tokens[-1])
  end

  def evaluate_tokens(tokens)
    tokens = process_parentheses(tokens)
    tokens = process_exponentiation(tokens)
    tokens = process_precedence(tokens, %w[* / %])
    tokens = process_precedence(tokens, %w[+ -])

    raise ArgumentError, 'Invalid formula' if tokens.length != 1

    tokens[0]
  end

  def process_parentheses(tokens)
    while tokens.include?('(')
      start_idx = tokens.rindex('(')
      end_idx = find_closing_paren(tokens, start_idx)

      raise ArgumentError, 'Mismatched parentheses' if end_idx.nil?

      sub_tokens = tokens[start_idx + 1...end_idx]
      raise ArgumentError, 'Empty parentheses' if sub_tokens.empty?

      result = evaluate_sub_tokens(sub_tokens)
      tokens[start_idx..end_idx] = [result]
    end

    raise ArgumentError, 'Mismatched parentheses' if tokens.include?(')')

    tokens
  end

  def find_closing_paren(tokens, start_idx)
    idx = tokens[start_idx + 1..].index(')')
    idx.nil? ? nil : start_idx + 1 + idx
  end

  def evaluate_sub_tokens(tokens)
    tokens = process_exponentiation(tokens)
    tokens = process_precedence(tokens, %w[* / %])
    tokens = process_precedence(tokens, %w[+ -])

    raise ArgumentError, 'Invalid sub-expression' if tokens.length != 1

    tokens[0]
  end

  def process_exponentiation(tokens)
    i = tokens.length - 2
    while i >= 1
      if tokens[i] == '^'
        left = tokens[i - 1]
        right = tokens[i + 1]

        raise ArgumentError, 'Invalid expression' if right.nil?

        result = power(left, right)
        tokens[i - 1..i + 1] = [result]
      end
      i -= 1
    end

    tokens
  end

  def process_precedence(tokens, operators)
    i = 1
    while i < tokens.length
      if operators.include?(tokens[i])
        left = tokens[i - 1]
        operator = tokens[i]
        right = tokens[i + 1]

        raise ArgumentError, 'Invalid expression' if right.nil?

        result = apply_operator(operator, left, right)
        tokens[i - 1..i + 1] = [result]
      else
        i += 2
      end
    end

    tokens
  end

  def apply_operator(operator, left, right)
    case operator
    when '+' then add(left, right)
    when '-' then subtract(left, right)
    when '*' then multiply(left, right)
    when '/' then divide(left, right)
    when '%' then modulo(left, right)
    when '^' then power(left, right)
    else
      raise ArgumentError, "Unknown operator: #{operator}"
    end
  end
end

# CLI interface for the calculator
class CalculatorCLI
  HELP_TEXT = <<~HELP
    Formula Calculator - Supports complex mathematical expressions

    Usage:
      calc.rb                    # Interactive mode
      calc.rb "2 + 3 * 4"        # Evaluate formula from argument
      calc.rb 2+3 "*" 4          # Evaluate formula from multiple arguments
      echo "2 + 3" | calc.rb     # Evaluate formula from stdin

    Operators (in order of precedence):
      ^   - Exponentiation (right-associative)
      * / - Multiplication, Division
      %   - Modulo
      + - - Addition, Subtraction
      ( ) - Parentheses for grouping

    Special variables:
      ans, _ - Reference the previous result (interactive mode only)

    Examples:
      Basic: 2 + 3, 10 - 4 * 2
      Parentheses: (2 + 3) * 4, ((2 + 3) * 4) - 1
      Negative numbers: -5 + 3, -(2 + 3), 5+-3, 5*-3
      Exponentiation: 2^3, 2^3^2 (evaluates right-to-left: 2^(3^2)=512)
      Modulo: 10 % 3, (7 + 3) % 4
      Complex: 2 + 3 * 4^2 - 10 / 5
      Using previous: ans * 2, _ + 10

    Special commands (interactive mode):
      help   - Show this help message
      quit   - Exit calculator
      q      - Exit calculator

    Tips:
      - Formulas are evaluated following standard mathematical precedence
      - Spaces are optional: "2+3*4" works the same as "2 + 3 * 4"
      - Use parentheses to override precedence: (2+3)*4
      - Exponentiation is right-associative: 2^3^2 = 2^(3^2) = 512
      - Quote operators like * in shell to prevent glob expansion
  HELP

  def initialize
    @calc = Calculator.new
    @last_result = nil
  end

  def run
    if ARGV.any?
      run_with_arguments
    elsif !$stdin.tty?
      run_with_stdin
    else
      run_interactive
    end
  end

  private

  def run_with_arguments
    formula = ARGV.join(' ')

    if %w[-h --help help].include?(formula.strip.downcase)
      puts HELP_TEXT
      return
    end

    evaluate_and_print(formula)
  rescue StandardError => e
    warn "Error: #{e.message}"
    exit 1
  end

  def run_with_stdin
    $stdin.each_line do |line|
      line = line.strip
      next if line.empty?

      evaluate_and_print(line)
    end
  rescue StandardError => e
    warn "Error: #{e.message}"
    exit 1
  end

  def run_interactive
    puts 'Formula Calculator'
    puts "Type 'help' for usage or 'quit' to exit\n\n"

    loop do
      input = prompt_input
      break if input.nil? || exit_command?(input)

      process_input(input)
      puts
    end

    puts 'Goodbye!'
  end

  def prompt_input
    print '> '
    read_input
  end

  def read_input
    input = read_raw_input
    input&.chomp
  end

  def read_raw_input
    if RELINE_AVAILABLE
      begin
        Reline.readline
      rescue StandardError
        $stdin.gets
      end
    else
      $stdin.gets
    end
  end

  def exit_command?(input)
    %w[quit q exit].include?(input.downcase.strip)
  end

  def process_input(input)
    input = input.strip
    return if input.empty?
    return puts HELP_TEXT if input.downcase == 'help'

    evaluate_formula(input)
  rescue StandardError => e
    puts "Error: #{e.message}"
  end

  def evaluate_formula(formula)
    @last_result = @calc.evaluate(formula, last_result: @last_result)
    puts "= #{format_result(@last_result)}"
  end

  def evaluate_and_print(formula)
    result = @calc.evaluate(formula)
    puts format_result(result)
  end

  def format_result(result)
    result == result.to_i ? result.to_i : result.round(10)
  end
end

if $PROGRAM_NAME == __FILE__
  cli = CalculatorCLI.new
  cli.run
end
