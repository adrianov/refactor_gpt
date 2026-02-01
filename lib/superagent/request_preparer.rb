# frozen_string_literal: true

# Request sanitization and model hint extraction. Only @-prefixed tokens (e.g. @sonnet) select a model.
module RequestPreparer
  NON_INTERACTIVE_NOTICE = /
    (?:^|\n)
    IMPORTANT:\s+This\s+agent\s+runs\s+in\s+non-interactive\s+mode\.
    .*?
    (?:make\s+all\s+decisions\s+autonomously|execute\s+tasks\s+directly|without\s+requesting\s+user\s+input)
    .*?
    \s*
  /mix
  GITIGNORE_PREPEND = "Ensure .gitignore excludes build artifacts, dependencies, and other unneeded files and folders. "
  MODEL_HINT_PATTERN = /@(\S+)/.freeze
  MODEL_HINT_SOURCES = [[:extract_from_at_mentions, :remove_at_mentions]].freeze

  module_function

  def prepend_gitignore_instruction(raw_req)
    base = raw_req.to_s.strip
    base.empty? ? GITIGNORE_PREPEND.strip : "#{GITIGNORE_PREPEND}#{raw_req}"
  end

  def sanitize_request(req, models)
    return req if req.nil?
    remove_model_mentions(req.gsub(NON_INTERACTIVE_NOTICE, "\n").strip, models)
  end

  # Returns model index when token is a valid model hint, else nil. Exact match first, then word-boundary in model name.
  def model_index_for_token(token, models)
    return nil if token.to_s.strip.empty?
    idx = models.index(token)
    return idx if idx
    re = /\b#{Regexp.escape(token)}\b/
    models.index { |name| name =~ re }
  end

  def extract_model_index(req, models)
    return nil if req.nil?

    MODEL_HINT_SOURCES.each do |extractor, _|
      idx = send(extractor, req, models)
      return idx if idx
    end
    nil
  end

  def extract_from_at_mentions(req, models)
    req.scan(MODEL_HINT_PATTERN).flatten.each do |token|
      idx = model_index_for_token(token, models)
      return idx if idx
    end
    nil
  end

  def remove_model_mentions(req, models)
    return req if req.nil?

    MODEL_HINT_SOURCES.reduce(req) do |text, (_, remover)|
      send(remover, text, models)
    end.strip
  end

  def remove_at_mentions(req, models)
    req.gsub(MODEL_HINT_PATTERN) do
      model_index_for_token(Regexp.last_match(1), models) ? '' : Regexp.last_match(0)
    end
  end
end
