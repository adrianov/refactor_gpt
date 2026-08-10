# frozen_string_literal: true

require 'uri'

# OpenRouter app attribution headers so usage shows as RefactorGPT instead of Unknown.
# https://openrouter.ai/docs/app-attribution
module OpenrouterHeaders
  REFERER = 'https://github.com/adrianov/refactor_gpt'
  TITLE = 'RefactorGPT'
  CATEGORIES = 'cli-agent'

  module_function

  def for_base_url(base_url)
    return {} unless openrouter_host?(base_url)

    {
      'HTTP-Referer' => REFERER,
      'X-OpenRouter-Title' => TITLE,
      'X-OpenRouter-Categories' => CATEGORIES
    }
  end

  def openrouter_host?(base_url)
    host = uri_host(base_url)
    host&.end_with?('openrouter.ai')
  end

  def same_host?(url_a, url_b)
    host_a = uri_host(url_a)
    host_b = uri_host(url_b)
    !host_a.nil? && host_a == host_b
  end

  def uri_host(url)
    URI.parse(url.to_s).host
  rescue URI::InvalidURIError
    nil
  end
end
