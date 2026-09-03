# frozen_string_literal: true

require 'uri'

# OpenRouter app attribution headers so usage shows as RefactorGPT instead of Unknown.
# https://openrouter.ai/docs/app-attribution
module OpenrouterHeaders
  REFERER = 'https://github.com/adrianov/refactor_gpt'
  TITLE = 'RefactorGPT'

  module_function

  def for_base_url(base_url)
    return {} unless openrouter_host?(base_url)

    {
      'HTTP-Referer' => REFERER,
      'X-Title' => TITLE
    }
  end

  def openrouter_host?(base_url)
    uri_host(base_url)&.end_with?('openrouter.ai')
  end

  def uri_host(url)
    URI.parse(url.to_s).host
  rescue URI::InvalidURIError
    nil
  end
end
