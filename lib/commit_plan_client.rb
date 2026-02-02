# frozen_string_literal: true

require "oj"
require "colorize"

# Calls the LLM to produce a commit plan (commits, warnings, quality_assessment, excluded_files).
class CommitPlanClient
  include AgentsFileHandler

  def initialize(model: nil, debug: false)
    @client = OpenAiClient.new(model: model, debug: debug,
      progress_title: "Planning commits".cyan)
    @diff_processor = DiffProcessor.new
  end

  def ask(prompts, json: false)
    @client.ask(prompts, json: json)
  end

  def commit_plan(status_output, diff_output, cli_hint, recent_commits,
    recent_commands)
    messages = [
      {role: "system", content: system_instruction},
      {role: "user",
       content: build_user_content(status_output, diff_output, cli_hint, recent_commits,
         recent_commands)}
    ]
    payload_size_kb = calculate_payload_size(messages)
    raw_response = ask(messages, json: true)
    parse_commit_plan_response(raw_response, payload_size_kb)
  end

  private

  MAX_CONTENT_SIZE_KB = 100

  def append_section(parts, current_size_bytes, max_size_bytes, text)
    return current_size_bytes if text.empty? || current_size_bytes + text.bytesize > max_size_bytes

    parts << text
    current_size_bytes + text.bytesize
  end

  def append_hint_section(parts, current_size_bytes, max_size_bytes, cli_hint)
    return current_size_bytes if cli_hint.empty?
    append_section(parts, current_size_bytes, max_size_bytes,
      "Here are hints or preferences from the user:\n\n#{cli_hint}\n")
  end

  def append_status_section(parts, current_size_bytes, max_size_bytes, status_output)
    append_section(parts, current_size_bytes, max_size_bytes,
      "Here is the git status:\n\n#{status_output}\n")
  end

  def append_diff_section(parts, current_size_bytes, max_size_bytes, diff_output, status_output)
    diff_text = "Here is the git diff for all changes:\n\n"
    remaining = max_size_bytes - current_size_bytes - diff_text.bytesize
    if remaining > 0
      sorted_diff = @diff_processor.build_sorted_diff(diff_output, status_output, remaining)
      diff_text += sorted_diff
      parts << diff_text
      current_size_bytes + diff_text.bytesize
    else
      parts << "#{diff_text}(Diff truncated: exceeds #{MAX_CONTENT_SIZE_KB} KB limit)\n"
      current_size_bytes
    end
  end

  def append_commits_section(parts, current_size_bytes, max_size_bytes, recent_commits)
    append_section(parts, current_size_bytes, max_size_bytes,
      "Here are the last 15 git commit one-line messages (most recent first):\n\n#{recent_commits}\n")
  end

  def append_commands_section(parts, current_size_bytes, max_size_bytes, recent_commands)
    return current_size_bytes if recent_commands.empty?
    append_section(parts, current_size_bytes, max_size_bytes,
      "Here are the last 5 shell commands from the user's terminal history " \
      "(most recent last):\n\n#{recent_commands}\n")
  end

  def build_user_content(status_output, diff_output, cli_hint, recent_commits,
    recent_commands)
    content_parts = []
    current_size_bytes = 0
    max_size_bytes = MAX_CONTENT_SIZE_KB * 1024

    current_size_bytes = append_hint_section(content_parts, current_size_bytes, max_size_bytes, cli_hint)

    current_size_bytes = append_status_section(content_parts, current_size_bytes, max_size_bytes, status_output)

    current_size_bytes = append_diff_section(content_parts, current_size_bytes, max_size_bytes, diff_output,
      status_output)

    current_size_bytes = append_commits_section(content_parts, current_size_bytes, max_size_bytes, recent_commits)

    append_commands_section(content_parts, current_size_bytes, max_size_bytes, recent_commands)

    content_parts.join("\n")
  end

  def parse_commit_plan_response(raw_response, payload_size_kb)
    json_str = raw_response.strip
    stripped_json_str = raw_response.gsub(/^```.*\n?/, "").gsub(/```$/, "").strip

    begin
      Oj.load(json_str)
    rescue Oj::ParseError
      Oj.load(stripped_json_str)
    end
  rescue Oj::ParseError
    puts "Failed to parse model response as JSON.".red
    puts "Payload size: #{payload_size_kb} KB".yellow
    puts "Raw response:\n#{raw_response}".red
    exit 1
  end

  def calculate_payload_size(messages)
    body = {model: @client.model, messages: messages, response_format: {type: "json_object"}}
    json_payload = Oj.dump(body, mode: :compat)
    (json_payload.bytesize / 1024.0).round(2)
  end

  def system_instruction
    sections = []

    sections << build_input_section
    sections << build_task_section
    sections << build_output_format_section

    sections.join
  end

  def build_input_section
    <<~HEREDOC
      You are a tool that analyzes and groups changed files into meaningful git commits.

      Input:
      - `git status --porcelain --branch` output (compact format showing current branch name, added, modified, deleted, renamed, untracked files)
      - unified git diff for all changes (including new files)
      - optional user-provided hints or preferences from the command line
      - last 15 git commit one-line messages to help you match existing style
      - last 5 shell commands from the user's terminal history to give you extra context

      Porcelain v1 format guide:
      - `## branch...upstream` - branch info line
      - ` M file.rb` - modified, not staged
      - `M  file.rb` - staged for commit
      - `MM file.rb` - modified and staged
      - `?? file.rb` - untracked
      - `R100 old.rb -> new.rb` - renamed (extract new.rb)
    HEREDOC
  end

  def build_task_section
    <<~HEREDOC
      Task:
      - Analyze the status and diff to infer logical groups of changes (by feature, bugfix, refactor, docs, tests, etc.).
      - **Code Assessment**: Thoroughly review all changes for potential issues:
        - Syntax errors or typos
        - Logic errors or incorrect implementations
        - Unused methods, variables, or constants left after refactoring
        - References to undefined methods, functions, or variables
        - Calls to deleted or moved code elements
        - Dead code that serves no purpose
        - Potential runtime errors or exceptions
        - Security vulnerabilities or unsafe practices
        - Performance issues or anti-patterns
      - **Language Detection**: Analyze recent commit messages to determine the primary language. Use the same language for new commits to maintain consistency. Default to English if no recent commits exist.
      - Create commit messages consistent with the style and language of provided recent commit messages.
      - Respect user-provided hints when choosing commit messages or grouping files, unless they conflict with actual diffs.
      - **JIRA Issue Reference Consistency** (critical rule):
        - Check branch name and recent commits for JIRA task references (patterns like PT-4668, ABC-123, etc.).
        - When multiple commits are created in one batch, MUST use the SAME JIRA issue reference for ALL commits
        - If branch name contains JIRA reference, ALL commits MUST reference that same issue
        - If recent commits show different JIRA issues, prefer the one from the branch name
        - If no JIRA reference exists in branch name or recent commits, do NOT add one
        - JIRA reference MUST be placed at the beginning of commit messages (e.g., "[PT-4668] type: description")
        - NEVER mix different JIRA issue references in the same commit batch
       - For each logical group, produce:
          - A one-line, conventional-style commit message (no trailing period) describing the atomic change
          - **Language principles**:
            - **English**: Use imperative verbs - "add X", "fix Y", "remove Z"
            - **Russian**: Use verbal nouns - "добавление X", "исправление Y", "удаление Z"
            - **Other languages**: Follow standard commit message conventions for that language
          - **Universal principles**:
            - Be specific about what changed and why
            - Avoid vague terms like "optimization", "improvement", "fix issues"
            - Focus on concrete actions and outcomes
          - A list of file paths to include in that commit
        - **Commit Ordering**: Organize commits to follow Test-Driven Development principles:
          - When implementing a new feature or fixing a bug, place test commits before implementation commits
          - If the original development followed TDD (tests written before code), preserve this sequence in commit ordering
          - Example ordering: "add failing tests for user authentication" → "implement user authentication logic"
          - When tests were written after implementation, group implementation and tests together in a single commit
          - Every changed file from status must appear in exactly one group OR in excluded_files
          - Extract complete file paths from status output by taking the full path after status flags (e.g., from "new file:   manifest.json", extract "manifest.json")
          - Never truncate or modify file paths - always use the complete filename including extensions
          - Prefer coherent commits over many tiny ones
        - **File Exclusion Rules**:
          - **schema.rb**: Exclude from commits if there are no database migration files in the changeset. Migration files are typically in `db/migrate/` directory with timestamps.
          - **Temporary and debug files**: Exclude from commits if changes are clearly temporary or debug-only, such as:
            - Files in `tmp/` directory
            - Files with `.log`, `.tmp`, `.temp`, `.bak`, `.swp`, `.swo` extensions
            - Debug console output added with `puts`, `p`, `pp`, or `debugger` statements that are not part of actual functionality
            - Test stub files in `spec/stubs/`, `test/stubs/`, `test/fixtures/` when unrelated to test code changes
          - For each excluded file, provide a clear reason in the excluded_files section.
        - **Overall Code Quality Assessment**: Analyze all changes and provide:
          - Whether overall code quality has increased or decreased
          - A brief explanation of why (focus on code organization, clarity, maintainability, bug fixes, or potential issues)
          - Keep assessment concise (2-3 sentences maximum)
        - For each detected issue, create a warning entry with:
          - The affected file path
          - A clear description of the potential error
          - A probability (0.0-1.0) indicating confidence this is a real issue
          - Any flaws in intended functionality implementation
    HEREDOC
  end

  def build_output_format_section
    <<~HEREDOC

      Return value format: strict JSON with these fields:
      {
        "quality_assessment": {
          "direction": "increased" | "decreased" | "unchanged",
          "explanation": "Brief explanation of why (2-3 sentences maximum)"
        },
        "commits": [
          {
            "message": "type: short description",
            "files": ["path/one.rb", "path/two.rb"]
          }
        ],
        "warnings": [
          {
            "file": "path/one.rb",
            "description": "Possible off-by-one error in loop bounds",
            "probability": 0.8,
            "start_line": 42,
            "end_line": 45
          }
        ],
        "excluded_files": [
          {
            "path": "db/schema.rb",
            "reason": "No database migrations in this changeset"
          }
        ]
      }

      If no issues are detected, return "warnings": [].
      For warnings: include start_line and end_line only when the issue can be pinpointed to specific lines in the diff. Omit these fields if the issue is general or spans the entire file.
      If no files are excluded, return "excluded_files": [].
      If code quality assessment is neutral/unclear, use "unchanged" for direction.

      Do not include any text outside of the JSON.
    HEREDOC
  end
end
