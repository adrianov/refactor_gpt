# frozen_string_literal: true

require "colorize"

# LLM client that answers YES/NO whether working-tree changes fulfill a request.
class Verify
  include AgentsFileHandler

  def initialize(model: nil, debug: false, project_root: Dir.pwd)
    @model = model
    @debug = debug
    @project_root = project_root
  end

  def ask(prompts)
    client = OpenrouterClient.new(model: @model, debug: @debug,
      progress_title: nil, raise_on_server_error: true)
    client.ask(prompts)
  rescue RubyLLM::ServerError => e
    warn "❌ Server error persisted after 3 retries: #{e.message}"
    exit 1
  end

  def assess_feature(user_request, status_output, diff_output)
    prompts = [
      {role: "system", content: system_instruction},
      {role: "user", content: build_user_content(user_request, status_output, diff_output)}
    ]
    print_full_prompt(prompts) if @debug
    ask(prompts)
  end

  private

  def print_full_prompt(prompts)
    warn '--- Full prompt ---'.light_black
    prompts.each do |msg|
      warn "[#{msg[:role].upcase}]".light_black
      warn msg[:content]
      warn ''
    end
    warn '--- End full prompt ---'.light_black
  end

  def build_user_content(user_request, status_output, diff_output)
    content_parts = [
      "User request: #{user_request}\n\n",
      "Here is the git status:\n#{status_output.to_s.strip}\n\n"
    ]

    unless diff_output.nil? || diff_output.to_s.strip.empty?
      content_parts << "Here is the git diff for all changes:\n#{diff_output.to_s.strip}\n"
    end

    content_parts.join("\n")
  end

  def system_instruction
    <<~HEREDOC
      You are a tool that verifies whether code changes fully implement a requested feature.

      Task:
      Verify that the code changes fully implement the user's request without introducing bugs or regressions.

      Available information:
      - Current user request
      - Final summary/response from the previous agent run that attempted to implement the feature

      Verification approach:
      - Review the previous agent's response to understand what was implemented
      - You may check git diff (using 'git diff') or read relevant files to verify the changes
      - Check if the changes address the user's request
      - Look for potential bugs, regressions, or missing functionality
      - Verify code quality and adherence to project guidelines

      Response format:
      - Start your response with "YES: " followed by a brief description if verification passes
      - Start your response with "NO: " followed by a brief description if verification fails

      CRITICAL requirements:
      - Your response MUST start with either "YES" or "NO" as the first word
      - Use minimal formatting only - avoid excessive markdown or formatting
      - Keep your response short and concise - one sentence is sufficient
      - The description after YES/NO should be brief and specific
      - DO NOT use thinking blocks or any other output format. Just the YES/NO response.
    HEREDOC
  end
end
