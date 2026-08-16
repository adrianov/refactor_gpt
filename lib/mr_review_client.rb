# frozen_string_literal: true

require "oj"
require "colorize"

# Calls the LLM to perform an automated code review of a merge request diff.
# Returns JSON with summary, warnings, suggestions, and quality_assessment.
class MrReviewClient
  include AgentsFileHandler

  MAX_DIFF_SIZE_KB = 300

  def initialize(model: nil, debug: false)
    @client = OpenAiClient.new(model: model, debug: debug,
      progress_title: "Reviewing MR".cyan)
  end

  def review(diff, branch:, base_branch:, recent_commits:)
    messages = [
      {role: "system", content: system_instruction},
      {role: "user", content: build_user_content(diff, branch: branch, base_branch: base_branch,
        recent_commits: recent_commits)}
    ]
    raw = @client.ask(messages, json: true)
    parse_response(raw)
  end

  private

  def build_user_content(diff, branch:, base_branch:, recent_commits:)
    parts = []
    parts << "Branch under review: `#{branch}` → `#{base_branch}`\n"
    parts << "Recent commits on this branch (most recent first):\n#{recent_commits}\n" unless recent_commits.empty?

    max_chars = MAX_DIFF_SIZE_KB * 1024
    truncated = diff.length > max_chars ? diff[0, max_chars] + "\n\n...(diff truncated)" : diff
    parts << "MR diff (`git diff -w -W --histogram #{base_branch}...HEAD`):\n\n```diff\n#{truncated}\n```\n"
    parts.join("\n")
  end

  def parse_response(raw)
    stripped = raw.gsub(/^```.*\n?/, "").gsub(/```$/, "").strip
    Oj.load(raw.strip)
  rescue Oj::ParseError
    begin
      Oj.load(stripped)
    rescue Oj::ParseError
      puts "Failed to parse review response as JSON.".red
      puts "Raw response:\n#{raw}".red
      exit 1
    end
  end

  def system_instruction
    prefix = formatted_project_rules(Dir.pwd)
    prefix.empty? ? review_instruction : "#{prefix}\n\n#{review_instruction}"
  end

  def review_instruction
    <<~HEREDOC
      You are an expert code reviewer performing an automated MR (merge request) review.

      Input:
      - Branch name and base branch
      - Recent commits on the branch for context
      - Full MR diff in unified format (`git diff -w -W --histogram`)

      Review the diff thoroughly for:
      - **Correctness**: Logic errors, off-by-one errors, incorrect implementations, broken edge cases
      - **Security**: SQL injection, XSS, insecure data handling, hardcoded secrets, unsafe deserialization
      - **Performance**: N+1 queries, unnecessary loops, missing indexes, expensive operations in hot paths
      - **Code quality**: Unused variables/methods, dead code, overly complex methods, missing error handling
      - **Naming and style**: Misleading names, inconsistent conventions, violation of project patterns
      - **Cursor rules**: leftover breaches of the project and user `.cursor/rules/` attached above
      - **Tests**: Missing tests for changed behavior, brittle assertions, untested edge cases
      - **Design**: Violation of SOLID/DRY/KISS, inappropriate responsibilities, poor abstractions

      For each issue assign a severity:
      - `critical` — must fix before merge (correctness, security, data loss risk)
      - `major` — strong recommendation (performance, reliability, significant code quality)
      - `minor` — improvement suggestion (style, naming, small refactors)
      - `info` — informational note (optional enhancements, praise, observations)

      Return strict JSON only — no text outside the JSON:
      {
        "summary": "2-4 sentence overall assessment of the MR",
        "quality_assessment": {
          "direction": "increased" | "decreased" | "unchanged",
          "explanation": "Brief explanation (2-3 sentences)"
        },
        "issues": [
          {
            "severity": "critical" | "major" | "minor" | "info",
            "file": "path/to/file.rb",
            "start_line": 42,
            "end_line": 45,
            "title": "Short issue title",
            "description": "Detailed explanation of the issue and how to fix it"
          }
        ],
        "suggestions": [
          "Concise actionable improvement that doesn't fit a specific line"
        ]
      }

      Rules:
      - `start_line` and `end_line` refer to the **new file** line numbers visible in the diff `+` lines. Omit when the issue is not line-specific.
      - Keep `description` focused: what is wrong and how to fix it.
      - If no issues found, return `"issues": []`.
      - If no general suggestions, return `"suggestions": []`.
      - Order issues by severity descending (critical first).
    HEREDOC
  end
end
