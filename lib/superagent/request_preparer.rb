# frozen_string_literal: true

# Request sanitization and model index extraction. Extracted to keep Superagent under length limit.
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

  module_function

  def prepend_gitignore_instruction(raw_req)
    base = raw_req.to_s.strip
    base.empty? ? GITIGNORE_PREPEND.strip : "#{GITIGNORE_PREPEND}#{raw_req}"
  end

  def sanitize_request(req, models)
    return req if req.nil?
    remove_model_mentions(req.gsub(NON_INTERACTIVE_NOTICE, "\n").strip, models)
  end

  def extract_model_index(req, models)
    return nil if req.nil?
    req.scan(/@(\S+)/).flatten.each do |mention|
      model_index = models.index(mention)
      return model_index if model_index
    end
    nil
  end

  def remove_model_mentions(req, models)
    return req if req.nil?
    cleaned = req.gsub(/@(\S+)/) do |match|
      models.include?($1) ? "" : match
    end
    cleaned.strip
  end
end
