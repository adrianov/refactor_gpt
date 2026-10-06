# frozen_string_literal: true

require "oj"

# Completes OpenRouter requests and normalizes JSON responses.
# The HTTP read runs on a side thread so Ctrl-C on the main thread can exit.
module OpenrouterResponse
  private

  def run(messages, json:, title:)
    message = translate_api_errors do
      complete_with_upstream_retries do
        complete_chat(build_chat(messages, json: json), messages, title)
      end
    end
    answer = ensure_answer!(json_fallback(answer_from(message), json: json), message)
    debug_response(answer) if @debug
    answer
  end

  # Requests complete without streaming; the estimated-speed bar gives feedback while
  # chat.complete runs. The read sits in OpenSSL or curl, which does not return on
  # SIGINT, so the call runs on a side thread and the main thread waits in Ruby.
  # Ctrl-C then raises here and the process exits. The bar is rebuilt on fallback
  # retry, so every attempt gets its own bar and finish runs even when the attempt fails.
  def complete_chat(chat, messages, title)
    progress = progress_for(messages, title)
    request = Thread.new { chat.complete }
    request.report_on_exception = false
    interruptible_result(request, progress)
  ensure
    finish_request(request, progress)
  end

  def progress_for(messages, title)
    return unless title

    PrimaryApiProgress.create(title: title, estimate_bytes: messages.to_s.bytesize, model: @model)
  end

  def interruptible_result(request, progress)
    PrimaryApiProgress.await(request)
  rescue Interrupt
    finish_request(request, progress)
    warn ''
    exit!(SignalHandler::EXIT_SIGINT)
  end

  def finish_request(request, progress)
    request&.kill if request&.alive?
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
