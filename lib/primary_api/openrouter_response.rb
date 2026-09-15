# frozen_string_literal: true

require "oj"

# Completes OpenRouter requests and normalizes JSON responses.
module OpenrouterResponse
  private

  def run(messages, json:, title:)
    message = translate_api_errors do
      complete_with_upstream_retries do
        chat = build_chat(messages, json: json)
        title ? complete_with_progress(chat, messages, title) : chat.complete
      end
    end
    answer = ensure_answer!(json_fallback(answer_from(message), json: json), message)
    debug_response(answer) if @debug
    answer
  end

  # Requests complete without streaming; the estimated-speed bar gives feedback while
  # the blocking chat.complete runs. The bar is rebuilt on fallback retry, so every
  # attempt gets its own bar and finish runs even when the attempt fails.
  def complete_with_progress(chat, messages, title)
    progress = PrimaryApiProgress.create(title: title, estimate_bytes: messages.to_s.bytesize)
    chat.complete
  ensure
    progress&.finish
  end

  def answer_from(message)
    text = message.content.is_a?(String) ? message.content : message.content.to_s
    return text unless text.strip.empty?
    return message.thinking.text.to_s if message.thinking&.text

    text
  end

  def json_fallback(answer, json:)
    return answer unless json && !OpenrouterJson.valid?(answer)

    OpenrouterJson.extract_from_text(answer) || answer
  end

  def ensure_answer!(answer, message)
    return answer unless answer.nil? || answer.strip.empty?

    warn "No answer returned from OpenRouter API. Full response body:"
    warn format_body(error_body(message))
    exit 1
  end

  def debug_request(messages, params)
    warn "--- OpenRouter request payload (#{primary_api_error_endpoint}) ---"
    warn Oj.dump({
      model: @model,
      params: params,
      messages: messages.map do |message|
        content = message_content(message)
        content.is_a?(String) ? {role: message_role(message), content_lines: content.split("\n")} : message
      end
    }, mode: :compat, indent: 2)
    warn "--- end payload ---"
  end

  def debug_response(answer)
    warn "\n--- OpenRouter response content ---"
    warn answer
    warn "--- end response ---\n"
  end
end
