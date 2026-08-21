# frozen_string_literal: true

require 'digest'
require 'ruby_llm'

# Applies prompt-cache markers when the provider supports them.
# OpenRouter Anthropic/Qwen/Gemini and openrouter/auto: cache_control breakpoints + prompt_cache_key.
# Auto also gets session_id (process-scoped by default) so the router pins model+provider.
# Other OpenRouter models: prompt_cache_key for sticky routing only.
# Non-OpenRouter base URLs get nothing — direct providers reject these params.
# https://openrouter.ai/docs/guides/best-practices/prompt-caching
module PromptCache
  KEY_PREFIX = 'refactor-sys-'
  SESSION_MAX = 256
  EPHEMERAL = {type: 'ephemeral'}.freeze
  EXPLICIT_MODEL = %r{\A(anthropic/|claude-|qwen/|alibaba/|google/gemini-|gemini-)}i

  module_function

  # Top-level request params merged into the chat payload.
  def request_params(messages, model:, base_url:, session_id: nil)
    return {} unless openrouter?(base_url)

    text = system_text(messages)
    return {} if text.strip.empty?

    params = { prompt_cache_key: cache_key(text) }
    explicit = explicit_breakpoints?(model) || auto?(model)
    params[:cache_control] = EPHEMERAL if explicit
    params[:session_id] = session_stamp(session_id) if auto?(model)
    params
  end

  # Wraps system text in a raw content block carrying the ephemeral cache_control marker.
  def cached_messages(messages, model:, base_url:)
    return messages unless openrouter?(base_url)
    return messages unless explicit_breakpoints?(model) || auto?(model)

    messages.map { |message| system_with_cache(message) }
  end

  def cache_key(text)
    "#{KEY_PREFIX}#{Digest::SHA256.hexdigest(text)[0, 16]}"
  end

  def auto?(model)
    wire_model(model).casecmp?('auto')
  end

  def explicit_breakpoints?(model)
    wire_model(model).match?(EXPLICIT_MODEL)
  end

  def session_stamp(session_id)
    sid = session_id.to_s.strip
    sid = "refactor-#{Process.pid}" if sid.empty?
    sid[0, SESSION_MAX]
  end

  def system_with_cache(message)
    role = message[:role] || message['role']
    content = message[:content] || message['content']
    return message unless cacheable_system_text?(role, content)

    message.merge(content: RubyLLM::Content::Raw.new([{type: 'text', text: content.to_s, cache_control: EPHEMERAL}]))
  end

  def cacheable_system_text?(role, content)
    role.to_s == 'system' && !content.is_a?(Array) && !content.is_a?(RubyLLM::Content::Raw) &&
      !content.to_s.strip.empty?
  end

  def system_text(messages)
    Array(messages).filter_map do |message|
      next unless (message[:role] || message['role']).to_s == 'system'

      content_text(message[:content] || message['content'])
    end.join
  end

  def content_text(content)
    content.is_a?(Array) ? content.filter_map { |block| block[:text] || block['text'] }.join : content.to_s
  end

  def wire_model(model)
    model.to_s.strip.sub(%r{\Aopenrouter/}i, '').delete_prefix('~')
  end

  def openrouter?(base_url)
    OpenrouterHeaders.openrouter_host?(base_url)
  end
end
