#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/openai_client"
require "ruby-progressbar"
require "rbconfig"

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

  def self.valid_file_path?(path, base_dir)
    File.file?(path) && path.start_with?(base_dir + File::SEPARATOR)
  end

  def self.build_file_snippet(path, base_dir)
    relative_path = path.sub(base_dir + File::SEPARATOR, "")
    "File: #{relative_path}\n#{File.read(path)}"
  end

  def self.build_question(parts, snippets)
    return parts.join(" ") if snippets.empty?

    <<~HEREDOC
      #{parts.join(" ")}

      Included files:
      #{snippets.join("\n\n---\n\n")}
    HEREDOC
  end

  def self.total_size(snippets)
    [snippets.sum(&:bytesize), 2000].max
  end

  def self.display_answer(answer)
    return puts answer unless glow_available?

    urls = extract_urls(answer)
    width = calculate_width(urls)
    formatted = format_answer(answer)

    display_with_glow(formatted, width)
  end

  def self.glow_available?
    system("command -v glow >/dev/null 2>&1")
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
    line.gsub(/\e\[[\d;]+m ?\e\[0m/, "")
      .gsub(/\e\[[\d;]+m ?\e\[0m/, "")
      .sub(/^(\e\[\d+m)?  /, "")
  end

  def self.init_options
    FLAG_MAPPING.values.map { |k| [k, false] }.to_h
  end

  def self.read_stdin_question
    input = $stdin.read
    if input.nil? || input.strip.empty?
      warn "No question provided. Exiting."
      exit 1
    end
    [input.strip]
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
    if system_info.empty?
      system_instr
    else
      <<~HEREDOC
        #{system_instr.strip}

        User environment:
        #{system_info}
      HEREDOC
    end
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

  def ask(messages)
    @client.ask(messages)
  end
end

# Main application
def main
  args = Utility.parse_args(Dir.pwd)

  show_interactive_prompt(args)
  client = create_client(args)
  messages = initialize_conversation(client, args)

  run_conversation_loop(client, messages, args)
end

def show_interactive_prompt(args)
  return unless args[:question_parts].empty? && $stdin.tty?

  puts "Enter your questions (empty line to exit):"
  puts "Available commands: --search, --no-search"
end

def create_client(args)
  AskGptClient.new(
    model: args[:search_mode] ? AskGptClient::SEARCH_MODEL : nil,
    max_completion_tokens: args[:short_mode] ? 500 : nil,
    debug: args[:debug_mode]
  )
end

def initialize_conversation(client, args)
  [client.build_system_message(args[:eldritch_mode] ? :eldritch : nil,
    args[:short_mode] ? :short : nil)]
end

def run_conversation_loop(client, messages, args)
  loop do
    question = get_question(args)
    break unless question

    handle_mode_switch(client, question) if args[:question_parts].empty?
    next if question == "--no-search"

    process_question(client, messages, question)
    clear_args_for_next_iteration(args)
  end
end

def get_question(args)
  if args[:question_parts].empty?
    print "> "
    input = $stdin.gets
    return nil if input.nil?

    input = input.strip
    return nil if input.empty?

    input
  else
    Utility.build_question(args[:question_parts], args[:file_snippets])
  end
end

def handle_mode_switch(client, input)
  if input == "--search"
    client.enable_search_mode
  elsif input == "--no-search"
    client.disable_search_mode
    puts "Switched to normal mode"
  end
end

def process_question(client, messages, question)
  messages << {role: "user", content: question}
  answer = client.ask(messages)
  messages << {role: "assistant", content: answer}
  Utility.display_answer(answer)
  puts
end

def clear_args_for_next_iteration(args)
  args[:question_parts] = []
  args[:file_snippets] = []
end

main if __FILE__ == $PROGRAM_NAME
