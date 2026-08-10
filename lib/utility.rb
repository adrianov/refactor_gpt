# frozen_string_literal: true

# Argument parsing, .env loading, and display helpers shared by ask_gpt and superagent.
module Utility
  PROJECT_ROOT = File.expand_path(File.join(__dir__, '..')).freeze
  FLAG_MAPPING = {"--search" => :search_mode, "--eldritch" => :eldritch_mode, "--short" => :short_mode,
                  "--debug" => :debug_mode}.freeze

  def self.parse_args(base_dir)
    options = init_options
    question_parts = []
    file_snippets = []

    ARGV.each do |arg|
      process_argument(arg, base_dir, options, question_parts, file_snippets)
    end

    options.merge(question_parts: question_parts, file_snippets: file_snippets)
  end

  def self.process_argument(arg, base_dir, options, question_parts, file_snippets)
    if FLAG_MAPPING.key?(arg)
      options[FLAG_MAPPING[arg]] = true
    else
      path = File.expand_path(arg, base_dir)
      if valid_file_path?(path, base_dir)
        file_snippets << build_file_snippet(path, base_dir)
      else
        question_parts << arg
      end
    end
  end

  def self.valid_file_path?(path, _base_dir)
    File.file?(path)
  end

  def self.build_file_snippet(path, base_dir)
    relative_path = path.start_with?(base_dir + File::SEPARATOR) ? path.sub(base_dir + File::SEPARATOR, "") : path
    "File: #{relative_path}\n#{File.read(path)}"
  end

  def self.build_question(parts, snippets)
    return parts.join(" ") if snippets.empty?

    "#{parts.join(" ")}\n\nIncluded files:\n#{snippets.join("\n\n---\n\n")}\n"
  end

  def self.total_size(snippets)
    [snippets.sum(&:bytesize), 2000].max
  end

  def self.display_answer(answer)
    has_tables = contains_tables?(answer)

    if has_tables && glow_available?
      return display_with_glow(format_answer(answer), calculate_width(extract_urls(answer)))
    end

    return render_with_md2term(answer) if md2term_available?

    puts answer
  end

  def self.contains_tables?(text)
    lines = text.split("\n")
    lines.each_with_index do |line, index|
      next unless trim(line).match?(/\|.*\|/)

      next_line = lines[index + 1]
      return true if next_line && trim(next_line).match?(/^[\|\s:-\|]+$/) && next_line.include?("-")
    end
    false
  end

  def self.glow_available?
    @glow_available ||= system("command -v glow >/dev/null 2>&1")
  end

  def self.md2term_available?
    @md2term_available ||= system("command -v md2term >/dev/null 2>&1")
  end

  def self.render_with_md2term(answer)
    IO.popen(ENV.to_h.merge({"CLICOLOR_FORCE" => "1"}),
      ["md2term", "-"], "w") do |io|
      io.write(answer)
    end
  end

  def self.stream_with_md2term
    IO.popen(ENV.to_h.merge({"CLICOLOR_FORCE" => "1"}),
      ["md2term", "-"], "w") do |io|
      yield io
    end
  end

  def self.extract_urls(answer)
    answer.scan(%r{\[.*?\]\(https?://[^)]+\)|https?://[^\s)]+})
  end

  def self.calculate_width(urls)
    return "100" if urls.empty?

    [urls.map(&:length).max + 2, 100].max.to_s
  end

  def self.format_answer(answer)
    answer.gsub(%r{\(\s*\n\s*(https?://[^)]+)\)}, '(\\1)')
      .gsub(%r{(\[.*?\]\(https?://[^)]+\))}, "\n\n\\1")
  end

  def self.display_with_glow(formatted, width)
    IO.popen(ENV.to_h.merge({"CLICOLOR_FORCE" => "1"}),
      ["glow", "--width", width, "--style", "dark", "-"], "w+") do |io|
      io.write(formatted)
      io.close_write

      io.each_line do |line|
        puts clean_glow_line(line)
      end
    end
  end

  def self.clean_glow_line(line)
    line
      .gsub(/(\e\[[\d;]+m\s*)+$/, "\e[0m")
      .sub(/^.*?  /, "")
  end

  def self.init_options
    FLAG_MAPPING.values.map { |k| [k, false] }.to_h
  end

  def self.trim(str)
    str.to_s.strip
  end

  def self.blank?(str)
    str.nil? || trim(str).empty?
  end

  def self.present?(str)
    !blank?(str)
  end

  def self.read_stdin_question
    input = $stdin.read
    exit 0 if blank?(input)
    [trim(input)]
  end

  def self.load_env_vars
    env_file_path = File.join(PROJECT_ROOT, '.env')
    return {} unless File.exist?(env_file_path)

    # Binary read + scrub avoids US-ASCII locale crashes on non-ASCII .env bytes.
    File.binread(env_file_path).force_encoding(Encoding::UTF_8).scrub('').each_line.with_object({}) do |line, h|
      key, value = line.split('=', 2)
      h[trim(key)] = trim(value) if present?(key) && value
    end
  end

  def self.gemini_configured?
    env_vars = load_env_vars
    env_vars.key?("GEMINI_ACCESS_TOKEN") && !env_vars["GEMINI_ACCESS_TOKEN"].empty?
  end

  def self.openai_configured?
    env_vars = load_env_vars
    env_vars.key?("OPENAI_ACCESS_TOKEN") && !env_vars["OPENAI_ACCESS_TOKEN"].empty?
  end

  def self.display_model_info(provider, model_name = nil)
    display_model = model_name || ((provider == :gemini) ? "gemini-3-flash" : "default")
    puts "Using: #{provider.to_s.capitalize} (#{display_model})"
  end
end
