#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/loader"

# Main application
def main
  args = Utility.parse_args(Dir.pwd)
  show_interactive_prompt(args)
  question = get_question(args) if args[:question_parts].empty?
  client = create_client(args)
  run_with_question_or_loop(client, initialize_conversation(client, args), question, args)
end

def run_with_question_or_loop(client, messages, question, args)
  if question
    process_question(client, messages, question, args)
    if $stdin.tty?
      clear_args_for_next_iteration(args)
      run_interactive_loop(client, messages, args)
    end
  else
    run_conversation_loop(client, messages, args)
  end
end

def show_interactive_prompt(args)
  return unless args[:question_parts].empty? && $stdin.tty?

  puts "Enter your questions (Ctrl+D to exit):"
  puts "Use arrow keys for history, Tab for completion"
  puts "For multiline input, press Enter twice to submit"
  puts ""
end

def create_client(args)
  AskGptClient.new(model: OpenrouterClient.default_model,
    max_completion_tokens: args[:short_mode] ? 500 : nil, debug: args[:debug_mode])
end

def initialize_conversation(client, args)
  puts "Using: OpenRouter (#{client.model})"
  [client.build_system_message(args[:eldritch_mode] ? :eldritch : nil,
    args[:short_mode] ? :short : nil)]
end

def run_conversation_loop(client, messages, args)
  if $stdin.tty?
    run_interactive_loop(client, messages, args)
  else
    question = get_question(args)
    process_question(client, messages, question, args) if question
  end
end

def run_interactive_loop(client, messages, args)
  loop do
    question = get_question(args)
    break unless question

    process_question(client, messages, question, args)
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


def process_question(client, messages, question, args)
  text_question = if args[:question_parts].empty?
    question
  else
    args[:question_parts].join(" ")
  end

  corrected_question, reason = correct_grammar(client, text_question)
  display_corrected_question(text_question, corrected_question, reason)

  messages << {role: "user", content: Utility.build_question([corrected_question], args[:file_snippets] || [])}

  process_with_buffering(client, messages)

  puts
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

  grammar_messages = [{role: "system", content: grammar_instruction}, {role: "user", content: question}]

  parse_correction_response(client.ask(grammar_messages, title: "Reviewing grammar"), question)
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
