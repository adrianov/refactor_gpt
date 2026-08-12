# frozen_string_literal: true

require 'digest'

# Applies prompt-cache markers when the provider supports them.
# OpenRouter Anthropic/Qwen: cache_control breakpoints + prompt_cache_key.
# Other OpenRouter models: prompt_cache_key for sticky routing only.
# Direct OpenAI Chat Completions rejects prompt_cache_key — never send it there.
# https://openrouter.ai/docs/guides/best-practices/prompt-caching
module PromptCache
  KEY_PREFIX = 'refactor-sys-'
  EPHEMERAL = {type: 'ephemeral'}.freeze
  EXPLICIT_MODEL = %r{\A(anthropic/|claude-|qwen/|alibaba/)}i

  module_function

  def apply!(body, model:, base_url: nil)
    return unless openrouter?(base_url)
    return if system_text(body[:messages]).strip.empty?

    if explicit_breakpoints?(model)
      apply_explicit!(body)
    else
      assign_cache_key!(body)
    end
  end

  def cache_key(text)
    "#{KEY_PREFIX}#{Digest::SHA256.hexdigest(text)[0, 16]}"
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
