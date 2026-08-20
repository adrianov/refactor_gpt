# frozen_string_literal: true

require 'digest'

# Applies prompt-cache markers when the provider supports them.
# OpenRouter Anthropic/Qwen/Gemini and openrouter/auto: cache_control breakpoints + prompt_cache_key.
# Auto also gets session_id (process-scoped by default) so the router pins model+provider.
# Other OpenRouter models: prompt_cache_key for sticky routing only.
# Direct OpenAI Chat Completions rejects prompt_cache_key — never send it there.
# https://openrouter.ai/docs/guides/best-practices/prompt-caching
module PromptCache
  KEY_PREFIX = 'refactor-sys-'
  SESSION_MAX = 256
  EPHEMERAL = {type: 'ephemeral'}.freeze
  EXPLICIT_MODEL = %r{\A(anthropic/|claude-|qwen/|alibaba/|google/gemini-|gemini-)}i

  module_function

  def apply!(body, model:, base_url: nil, session_id: nil)
    return unless openrouter?(base_url)
    return if system_text(body[:messages]).strip.empty?

    if explicit_breakpoints?(model) || auto?(model)
      apply_explicit!(body)
    else
      assign_cache_key!(body)
    end
    stamp_session!(body, model: model, session_id: session_id)
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

  def apply_explicit!(body)
    body[:cache_control] = EPHEMERAL
    body[:messages] = Array(body[:messages]).map { |message| system_with_cache(message) }
    assign_cache_key!(body)
  end

  def assign_cache_key!(body)
    text = system_text(body[:messages])
    body[:prompt_cache_key] = cache_key(text) unless text.strip.empty?
  end

  def stamp_session!(body, model:, session_id:)
    return unless auto?(model)

    sid = session_id.to_s.strip
    sid = "refactor-#{Process.pid}" if sid.empty?
    body[:session_id] = sid[0, SESSION_MAX]
  end

  def system_with_cache(message)
    role = message[:role] || message['role']
    content = message[:content] || message['content']
    return message unless role.to_s == 'system' && !content.is_a?(Array)
    return message if content.to_s.strip.empty?

    message.merge(content: [{type: 'text', text: content.to_s, cache_control: EPHEMERAL}])
  end

  def system_text(messages)
    Array(messages).filter_map do |message|
      role = message[:role] || message['role']
      next unless role.to_s == 'system'

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
