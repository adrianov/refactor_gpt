#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/loader"

# Main application
def main
  args = Utility.parse_args(Dir.pwd)
  show_interactive_prompt(args)
  question = get_question(args) if args[:question_parts].empty?
  client = create_client(args)
  messages = initialize_conversation(client, args)
  run_with_question_or_loop(client, messages, question, args)
end

def run_with_question_or_loop(client, messages, question, args)
  if question
    handle_mode_switch(client, question) if args[:question_parts].empty?
    process_question(client, messages, question, use_streaming?(client), args) unless question == "--no-search"
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
  puts "Note: Backend is chosen from MODEL in .env (claude-* / gemini-* / gpt-*)"
end

def create_client(args)
  env = ENV.to_h.merge(Utility.load_env_vars)
  model = args[:search_mode] ? AskGptClient::SEARCH_MODEL : LlmRouter.default_model(env)
  config = LlmRouter.config_for_model(model, env)
  if config.nil?
    print_config_error
    return
  end
  build_client_from_config(config, args)
end

def build_client_from_config(config, args)
  use_streaming = Utility.md2term_available? && config[:backend] == :gemini && !args[:search_mode]
  common = {
    model: config[:model],
    max_completion_tokens: args[:short_mode] ? 500 : nil,
    debug: args[:debug_mode],
    api_base_url: config[:base_url],
    api_key: config[:access_token]
  }
  if config[:backend] == :gemini
    AskGeminiClient.new(**common, progress: !use_streaming)
  else
    AskGptClient.new(**common, backend: config[:backend])
  end
end

def print_config_error
  warn "❌ No API configuration found. Set MODEL (or CLAUDE_/OPENAI_/GEMINI_ACCESS_TOKEN) in .env"
  exit 1
end

def initialize_conversation(client, args)
  Utility.display_model_info(client.backend, client.model)

  if client.backend == :gemini
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
  PromptReader.read_multiline
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
