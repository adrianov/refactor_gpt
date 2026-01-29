#!/usr/bin/env ruby
# frozen_string_literal: true

SCRIPT_DIR = File.expand_path(File.dirname(__FILE__)).freeze

require_relative "lib/openai_client"
require_relative "lib/gemini_client"
require_relative "lib/completion_notifier"
require "ruby-progressbar"
require "rbconfig"
require "reline"

# System information detection
class SystemInfo
  PLATFORM_PATTERNS = {/darwin/ => "macOS", /linux/ => "Linux",
                       /mswin|mingw|cygwin/ => "Windows"}.freeze

  def self.to_s
    @to_s ||= begin
      os = RbConfig::CONFIG["host_os"].downcase
      platform = detect_platform(os)
      version = detect_version(platform)
      desktop = detect_desktop
      format_info(platform, version, desktop)
    rescue
      ""
    end
  end

  def self.detect_platform(os)
    PLATFORM_PATTERNS.find { |p, _| os.match?(p) }&.last ||
      if os.match?(/linux/)
        if File.exist?("/etc/os-release") && File.read("/etc/os-release") =~ /^NAME="?Ubuntu"?/i
          "Ubuntu"
        else
          "Linux"
        end
      else
        RbConfig::CONFIG["host_os"]
      end
  end

  def self.detect_version(platform)
    case platform
    when "macOS" then `sw_vers -productVersion 2>/dev/null`.strip
    when "Ubuntu"
      return "" unless File.exist?("/etc/os-release")

      File.read("/etc/os-release").match(/^VERSION="?([^"\n]+)"?/)&.[](1)&.strip || ""
    when "Windows" then `wmic os get Version /value 2>NUL`.split("=").last.to_s.strip
    else ""
    end
  end

  def self.detect_desktop
    [
      ENV["XDG_CURRENT_DESKTOP"],
      ENV["DESKTOP_SESSION"],
      ENV["GNOME_DESKTOP_SESSION_ID"] ? "GNOME" : nil,
      (ENV["KDE_FULL_SESSION"] == "true") ? "KDE" : nil,
      ENV["XDG_SESSION_TYPE"]
    ].compact.join(" ")
  end

  def self.format_info(platform, version, desktop)
    info = "OS: #{platform}"
    info += ", Version: #{version}" unless version.empty?
    info += ", Desktop: #{desktop}" unless desktop.empty?
    info
  end

  def self.date_info
    `date`.strip
  rescue
    ""
  end
end

# Argument parsing and utilities
module Utility
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
      next unless line.strip.match?(/\|.*\|/)

      next_line = lines[index + 1]
      return true if next_line&.strip&.match?(/^[\|\s:-\|]+$/) && next_line.include?("-")
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

      # fixing glow output: we strip unneeded spaces surrounded by ANSI codes
      io.each_line do |line|
        puts clean_glow_line(line)
      end
    end
  end

  def self.clean_glow_line(line)
    line
      .gsub(/(\e\[[\d;]+m\s*)+$/, "\e[0m")
      .sub(/^.*?  /, "")
    # .gsub("\e", "~") # debug
  end

  def self.init_options
    FLAG_MAPPING.values.map { |k| [k, false] }.to_h
  end

  def self.read_stdin_question
    input = $stdin.read
    if input.nil? || input.strip.empty?
      exit 0
    end
    [input.strip]
  end

  def self.load_env_vars
    env_file_path = File.join(SCRIPT_DIR, ".env")
    return {} unless File.exist?(env_file_path)

    File.foreach(env_file_path).with_object({}) do |line, h|
      key, value = line.split("=", 2)
      h[key.strip] = value.strip if key && value
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

# OpenAI API client wrapper
class AskGptClient
  SEARCH_MODEL = "gpt-4o-search-preview"

  def initialize(model: nil, max_completion_tokens: nil, debug: false)
    @model = model
    @max_completion_tokens = max_completion_tokens
    @debug = debug
    @client = OpenAiClient.new(model: model, max_completion_tokens: max_completion_tokens, debug: debug,
      progress_title: "Thinking")
  end

  def build_system_message(style, brevity)
    {role: "system", content: build_system_instruction(style, brevity)}
  end

  def build_system_instruction(style, brevity)
    style_instr = build_style_instruction(style)
    style_instr += build_brevity_instruction if brevity == :short

    system_instr = base_instruction(style_instr)
    system_info = SystemInfo.to_s
    date_info = SystemInfo.date_info

    result = system_instr.strip
    result += "\n\nUser environment:\n#{system_info}" unless system_info.empty?
    result += "\nCurrent date/time: #{date_info}" unless date_info.empty?
    result
  end

  def build_style_instruction(style)
    return "Answer in a Lovecraftian, eldritch horror tone" if style == :eldritch

    <<~HEREDOC
      - Answer in clear, concise terms, prioritizing Ruby concepts and tooling.
      - Prefer idiomatic Ruby style in all code examples.
      - Use Markdown formatting (headings, lists, fenced code blocks) where helpful.
      - Default code fences to Ruby unless another language is clearly required.
      - Always respond using Markdown formatting, even for very short answers.
    HEREDOC
  end

  def build_brevity_instruction
    <<~HEREDOC
      Answer in 1–2 short, direct phrases; be as brief as possible while still being correct and useful.
      Avoid lists, headings, or multi-sentence paragraphs unless absolutely necessary.
      If a one-word answer would be fully correct and sufficient, answer with that one word.
    HEREDOC
  end

  def base_instruction(style_instr)
    <<~HEREDOC
      You are a Ruby-focused assistant helping a Ruby programmer.

      Style and format:
      #{style_instr}

      Answer length:
      - Be succinct and avoid unnecessary theory.
      - Include just enough detail and examples to make solution directly usable.
      - If user asks a short, direct question and does not explicitly request detail,
        respond with a short, direct answer (1–3 short sentences or bullet points) by default.
      - If the user's question can be fully answered with a single word (e.g., "yes", "no", a name, a number),
        respond with exactly that one word unless they explicitly ask for explanation.

      Code and explanations:
      - When showing code, make it copy-pastable and minimal.
      - Briefly explain non-obvious parts of the code.
      - If there are multiple reasonable approaches, mention the most common one first.

      Formatting restrictions:
      - Do not use Markdown tables, as they cannot be parsed properly.

      Translations:
      - Provide translations to Russian, English, French, German, Spanish, and Italian
      - Follow user-specified language pairs when provided
      - For short phrases: include translation, phonetics, and brief etymology when relevant

      Ruby gems:
      - When you recommend Ruby gems, always include a GitHub repository URL for each gem
        you mention, in form: `gem_name – https://github.com/owner/repo`
        whenever such a public repository is known or can be reasonably inferred.
    HEREDOC
  end

  def change_model(new_model)
    return if @model == new_model

    @model = new_model
    @client = OpenAiClient.new(model: @model, max_completion_tokens: @max_completion_tokens, debug: @debug,
      progress_title: "Thinking")
  end

  def search_mode?
    @model == SEARCH_MODEL
  end

  def enable_search_mode
    change_model(SEARCH_MODEL)
  end

  def disable_search_mode
    change_model(nil)
  end

  def chat(question, style: nil, brevity: nil)
    ask([{role: "system", content: build_system_instruction(style, brevity)},
      {role: "user", content: question}])
  end

  def ask(messages, json: false, title: nil)
    @client.ask(messages, json: json, title: title)
  end
end

class AskGeminiClient
  DEFAULT_MODEL = "gemini-3-flash"

  def initialize(model: nil, max_completion_tokens: nil, debug: false, progress: true)
    @model = model
    @max_completion_tokens = max_completion_tokens
    @debug = debug
    progress_title = progress ? "Thinking" : nil
    @client = GeminiClient.new(model: model, max_completion_tokens: max_completion_tokens, debug: debug,
      progress_title: progress_title)
  end

  def ask(messages, json: false, title: nil)
    @client.ask(messages, json: json, title: title)
  end

  def stream_answer(messages, &block)
    @client.stream_answer(messages, &block)
  end

  def build_system_message(style, brevity)
    {role: "user", content: build_system_instruction(style, brevity)}
  end

  def build_system_instruction(style, brevity)
    style_instr = build_style_instruction(style)
    style_instr += build_brevity_instruction if brevity == :short

    system_instr = base_instruction(style_instr)
    system_info = SystemInfo.to_s
    date_info = SystemInfo.date_info

    result = system_instr.strip
    result += "\n\nUser environment:\n#{system_info}" unless system_info.empty?
    result += "\nCurrent date/time: #{date_info}" unless date_info.empty?
    result
  end

  def build_style_instruction(style)
    return "Answer in a Lovecraftian, eldritch horror tone" if style == :eldritch

    <<~HEREDOC
      - Answer in clear, concise terms, prioritizing Ruby concepts and tooling.
      - Prefer idiomatic Ruby style in all code examples.
      - Use Markdown formatting (headings, lists, fenced code blocks) where helpful.
      - Default code fences to Ruby unless another language is clearly required.
      - Always respond using Markdown formatting, even for very short answers.
    HEREDOC
  end

  def build_brevity_instruction
    <<~HEREDOC
      Answer in 1–2 short, direct phrases; be as brief as possible while still being correct and useful.
      Avoid lists, headings, or multi-sentence paragraphs unless absolutely necessary.
      If a one-word answer would be fully correct and sufficient, answer with that one word.
    HEREDOC
  end

  def base_instruction(style_instr)
    <<~HEREDOC
      You are a Ruby-focused assistant helping a Ruby programmer.

      Style and format:
      #{style_instr}

      Answer length:
      - Be succinct and avoid unnecessary theory.
      - Include just enough detail and examples to make solution directly usable.
      - If user asks a short, direct question and does not explicitly request detail,
        respond with a short, direct answer (1–3 short sentences or bullet points) by default.
      - If the user's question can be fully answered with a single word (e.g., "yes", "no", a name, a number),
        respond with exactly that one word unless they explicitly ask for explanation.

      Code and explanations:
      - When showing code, make it copy-pastable and minimal.
      - Briefly explain non-obvious parts of the code.
      - If there are multiple reasonable approaches, mention the most common one first.

      Formatting restrictions:
      - Do not use Markdown tables, as they cannot be parsed properly.

      Translations:
      - Provide translations to Russian, English, French, German, Spanish, and Italian
      - Follow user-specified language pairs when provided
      - For short phrases: include translation, phonetics, and brief etymology when relevant

      Ruby gems:
      - When you recommend Ruby gems, always include a GitHub repository URL for each gem
        you mention, in form: `gem_name – https://github.com/owner/repo`
        whenever such a public repository is known or can be reasonably inferred.
    HEREDOC
  end

  def chat(question, style: nil, brevity: nil)
    ask([{role: "user", content: build_system_instruction(style, brevity)},
      {role: "user", content: question}])
  end
end

# Main application
def main
  args = Utility.parse_args(Dir.pwd)

  show_interactive_prompt(args)
  
  # Allow user to enter the request
  question = get_question(args) if args[:question_parts].empty?

  client = create_client(args)
  messages = initialize_conversation(client, args)

  if question
    # Process the pre-fetched question
    handle_mode_switch(client, question) if args[:question_parts].empty?
    process_question(client, messages, question, use_streaming?(client), args) unless question == "--no-search"
    
    # If interactive, continue loop
    if $stdin.tty?
      clear_args_for_next_iteration(args)
      run_interactive_loop(client, messages, args, use_streaming?(client))
    end
  else
    run_conversation_loop(client, messages, args)
  end
end

def show_interactive_prompt(args)
  return unless args[:question_parts].empty? && $stdin.tty?

  puts "Enter your questions (Ctrl+D to exit):"
  puts "Available commands: --search, --no-search"
  puts "Use arrow keys for history, Tab for completion"
  puts "For multiline input, press Enter twice to submit"
  puts ""
  puts "Note: Provider is auto-detected from .env (Gemini preferred)"
end

def create_client(args)
  use_streaming = Utility.md2term_available? && Utility.gemini_configured? && !args[:search_mode]

  if Utility.gemini_configured?
    init_gemini_client(args, use_streaming)
  elsif Utility.openai_configured?
    init_openai_client(args)
  else
    print_config_error
  end
end

def init_gemini_client(args, use_streaming)
  AskGeminiClient.new(
    model: nil,
    max_completion_tokens: args[:short_mode] ? 500 : nil,
    debug: args[:debug_mode],
    progress: !use_streaming
  )
end

def init_openai_client(args)
  AskGptClient.new(
    model: args[:search_mode] ? AskGptClient::SEARCH_MODEL : nil,
    max_completion_tokens: args[:short_mode] ? 500 : nil,
    debug: args[:debug_mode]
  )
end

def print_config_error
  warn "❌ No API configuration found. Please configure either:"
  warn "   • OpenAI: Set OPENAI_ACCESS_TOKEN in .env"
  warn "   • Gemini: Set GEMINI_ACCESS_TOKEN in .env"
  exit 1
end

def initialize_conversation(client, args)
  provider = (Utility.gemini_configured? && !args[:search_mode]) ? :gemini : :openai
  Utility.display_model_info(provider)

  if provider == :gemini
    [{role: "user", content: client.build_system_instruction(args[:eldritch_mode] ? :eldritch : nil,
      args[:short_mode] ? :short : nil)}]
  else
    [client.build_system_message(args[:eldritch_mode] ? :eldritch : nil,
      args[:short_mode] ? :short : nil)]
  end
end

def use_streaming?(client)
  Utility.md2term_available? && client.is_a?(AskGeminiClient)
end

def run_conversation_loop(client, messages, args)
  streaming = use_streaming?(client)

  if $stdin.tty?
    run_interactive_loop(client, messages, args, streaming)
  else
    question = get_question(args)
    process_question(client, messages, question, streaming, args) if question
  end
end

def run_interactive_loop(client, messages, args, streaming)
  loop do
    question = get_question(args)
    break unless question

    handle_mode_switch(client, question) if args[:question_parts].empty?
    next if question == "--no-search"

    process_question(client, messages, question, streaming, args)
    clear_args_for_next_iteration(args)
  end
end

def get_question(args)
  if args[:question_parts].empty?
    if $stdin.tty?
      get_interactive_question
    else
      get_piped_question
    end
  else
    Utility.build_question(args[:question_parts], args[:file_snippets])
  end
end

def get_interactive_question
  lines = []

  loop do
    line = Reline.readline(lines.empty? ? "> " : "  ", true)
    return nil if line.nil?

    line = line.strip
    if line.empty?
      break unless lines.empty?

      return nil
    end

    lines << line
  end

  lines.join("\n")
end

def get_piped_question
  input = $stdin.read
  if input.nil? || input.strip.empty?
    exit 0
  end
  input.strip
end

def handle_mode_switch(client, input)
  if input == "--search"
    client.enable_search_mode
  elsif input == "--no-search"
    client.disable_search_mode
    puts "Switched to normal mode"
  end
end

def process_question(client, messages, question, use_streaming, args)
  text_question = if args[:question_parts].empty?
    question
  else
    args[:question_parts].join(" ")
  end

  corrected_question, reason = correct_grammar(client, text_question)
  display_corrected_question(text_question, corrected_question, reason)

  full_corrected_question = Utility.build_question([corrected_question], args[:file_snippets] || [])
  messages << {role: "user", content: full_corrected_question}

  if use_streaming
    process_with_streaming(client, messages)
  else
    process_with_buffering(client, messages)
  end

  puts
end

def process_with_streaming(client, messages)
  full_text = ""
  spinner, spinner_thread = start_thinking_spinner
  first_chunk_received = false

  Utility.stream_with_md2term do |io|
    full_text, first_chunk_received = process_stream_chunks(client, messages, spinner,
      spinner_thread, io, first_chunk_received)
  end

  stop_thinking_spinner(spinner, spinner_thread) unless first_chunk_received

  messages << {role: "assistant", content: full_text}
end

def process_stream_chunks(client, messages, spinner, spinner_thread, io, first_chunk_received)
  full_text = ""
  chunk_received = first_chunk_received

  client.stream_answer(messages) do |chunk|
    if chunk && !chunk.to_s.empty? && !chunk_received
      stop_thinking_spinner(spinner, spinner_thread)
      chunk_received = true
    end

    text = chunk.to_s
    full_text += text
    io.write(text)
    io.flush
  end

  [full_text, chunk_received]
end

def start_thinking_spinner
  spinner = ProgressBar.create(
    title: "Thinking",
    total: 6000,
    format: "%t: |%B| %p%% %e",
    length: 100
  )

  thread = Thread.new do
    loop do
      break if spinner.finished?

      spinner.increment
      sleep 0.1
    end
  end

  [spinner, thread]
end

def stop_thinking_spinner(spinner, thread)
  return unless thread.alive?

  thread.kill
  spinner.finish unless spinner.finished?
  print "\r\e[K" # Clear the spinner line
end

def process_with_buffering(client, messages)
  answer = client.ask(messages)
  messages << {role: "assistant", content: answer}
  Utility.display_answer(answer)
end

def correct_grammar(client, question)
  return [question, nil] if question.lines.count > 2

  grammar_instruction = <<~HEREDOC
    Correct the grammar, spelling, and clarity of the following question or statement while preserving its exact meaning and intent.
    
    Style preservation:
    - Preserve the exact style (formal or informal) of the original input.
    - Do not convert informal speech to formal, or formal speech to informal.
    - If the input is informal, keep it informal; if formal, keep it formal.
    - You may suggest improvements within the same style (e.g., better informal phrasing, clearer formal structure).
    
    Return the response in this exact format:
    Corrected: [corrected text]
    Reason: [brief explanation of what was corrected]
    If the input is already grammatically correct, return it unchanged with "Reason: No changes needed".
  HEREDOC

  grammar_messages = if client.is_a?(AskGeminiClient)
    [{role: "user", content: "#{grammar_instruction}\n\n#{question}"}]
  else
    [{role: "system", content: grammar_instruction}, {role: "user", content: question}]
  end

  response = client.ask(grammar_messages, title: "Reviewing grammar")
  parse_correction_response(response, question)
rescue StandardError
  [question, nil]
end

def parse_correction_response(response, original)
  return [original, nil] unless response

  corrected_match = response.match(/Corrected:\s*(.+?)(?:\n|$)/i)
  reason_match = response.match(/Reason:\s*(.+?)(?:\n|$)/i)

  corrected = corrected_match ? corrected_match[1].strip : original
  reason = reason_match ? reason_match[1].strip : nil

  [corrected, reason]
end

def only_case_or_punctuation_change?(original, corrected)
  normalize_text(original) == normalize_text(corrected)
end

def normalize_text(text)
  text.strip
    .gsub(/[[:punct:]]/, "")
    .gsub(/\s+/, " ")
    .downcase
end

def display_corrected_question(original, corrected, reason)
  return if original.strip == corrected.strip
  return if only_case_or_punctuation_change?(original, corrected)

  puts "Corrected: #{corrected}"
  puts "Reason: #{reason}" if reason
  puts
end

def clear_args_for_next_iteration(args)
  args[:question_parts] = []
  args[:file_snippets] = []
end

if __FILE__ == $PROGRAM_NAME
  CompletionNotifier.setup_exit_hook
  main
end
