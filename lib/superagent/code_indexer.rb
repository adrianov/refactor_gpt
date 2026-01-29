# frozen_string_literal: true

require 'parser/current'
require 'set'

# Indexes Ruby classes, modules, and methods via Parser AST; supports trigram-scored
# search and collection of full symbol bodies (or whole file when class is most of file).
class CodeIndexer
  CODE_CONTEXT_MAX_LINES = 1000
  WHOLE_FILE_RATIO = 0.8

  def initialize(root_dir = '.')
    @root_dir = File.expand_path(root_dir)
    @index = {}
  end

  def build_index
    Dir.glob("#{@root_dir}/**/*.rb").each do |file|
      next if file.include?('/vendor/') || file.include?('/node_modules/')

      code = File.read(file)
      ast = Parser::CurrentRuby.parse(code)
      process_node(ast, file)
    rescue Parser::SyntaxError
      # Skip files with syntax errors
    end
    @index
  end

  def search(query, limit: 50)
    return [] if query.to_s.strip.empty?

    words = query.to_s.downcase.split
    trigrams = trigram_set(words.join)
    return [] if trigrams.empty?

    scored = @index.map do |name, locations|
      sym_trigrams = trigram_set(name.to_s.downcase)
      score = (trigrams & sym_trigrams).size
      [name, locations, score] if score.positive?
    end
    scored.compact.sort_by { |_, _, s| -s }.first(limit).flat_map { |name, locs, _| locs.map { |loc| [name, loc] } }
  end

  def collect_code(query, max_lines: CODE_CONTEXT_MAX_LINES)
    matches = search(query)
    return nil if matches.empty?

    collected = []
    used_ranges = Hash.new { |h, k| h[k] = [] }
    total_lines = 0

    matches.each do |name, loc|
      break if total_lines >= max_lines

      file = loc[:file]
      first_line = loc[:first_line]
      last_line = loc[:last_line]
      next if first_line.nil? || last_line.nil?

      file_lines = count_file_lines(file)
      span = last_line - first_line + 1

      if %i[class module].include?(loc[:type]) && file_lines.positive? &&
         (span.to_f / file_lines) >= WHOLE_FILE_RATIO
        range = [1, file_lines]
      else
        range = [first_line, last_line]
      end

      next if overlapping?(used_ranges[file], range)

      lines = read_line_range(file, range[0], range[1])
      next if lines.empty?

      total_lines += lines.size
      if total_lines > max_lines
        trim = lines.size - (total_lines - max_lines)
        lines = lines.first(trim) if trim.positive?
        total_lines = max_lines
      end

      used_ranges[file] << range
      collected << { name: name, type: loc[:type], file: file, first_line: range[0], lines: lines }
    end

    format_collected(collected)
  end

  private

  def trigram_set(s)
    return Set.new if s.length < 3

    Set.new((0..s.length - 3).map { |i| s[i, 3] })
  end

  def overlapping?(ranges, range)
    a, b = range
    ranges.any? { |c, d| (a <= d) && (b >= c) }
  end

  def count_file_lines(file)
    return 0 unless File.file?(file)

    File.read(file).count("\n") + 1
  end

  def read_line_range(file, first, last)
    return [] unless File.file?(file)

    all = File.readlines(file, chomp: false)
    all[(first - 1)..(last - 1)] || []
  end

  def format_collected(collected)
    return nil if collected.empty?

    parts = collected.map do |entry|
      header = "# #{entry[:type]}: #{entry[:name]} (#{entry[:file]}:#{entry[:first_line]})\n"
      header + entry[:lines].join
    end
    "\n\nRelevant code (Parser index, trigram match, max #{CODE_CONTEXT_MAX_LINES} lines):\n\n" + parts.join("\n\n")
  end

  def process_node(node, file, namespace = [])
    return unless node.is_a?(Parser::AST::Node)

    case node.type
    when :class, :module
      name = node.children[0].children[1].to_s
      full_name = (namespace + [name]).join('::')
      range = node.loc.expression
      add_index(full_name, node.type, file, range)
      node.children.each { |child| process_node(child, file, namespace + [name]) }
    when :def
      method_name = node.children[0].to_s
      full_name = (namespace + [method_name]).join('::')
      range = node.loc.expression
      add_index(full_name, :method, file, range)
    else
      node.children.each { |child| process_node(child, file, namespace) }
    end
  end

  def add_index(full_name, type, file, range)
    return unless range

    @index[full_name] ||= []
    @index[full_name] << {
      type: type,
      file: file,
      first_line: range.first_line,
      last_line: range.last_line
    }
  end
end
