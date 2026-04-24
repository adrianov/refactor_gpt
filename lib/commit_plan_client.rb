# frozen_string_literal: true

require "oj"
require "colorize"

# Calls the LLM to produce a commit plan (commits, warnings, quality_assessment impact summary, excluded_files).
class CommitPlanClient
  include AgentsFileHandler

  def initialize(model: nil, debug: false)
    @client = OpenAiClient.new(model: model, debug: debug,
      progress_title: "Planning commits".cyan)
  end

  def ask(prompts, json: false)
    @client.ask(prompts, json: json)
  end

  def commit_plan(status_output, mr_diff_output, uncommitted_diff_output, cli_hint, recent_commits,
    recent_commands)
    messages = [
      {role: "system", content: system_instruction},
      {role: "user",
       content: build_user_content(status_output, mr_diff_output, uncommitted_diff_output, cli_hint,
         recent_commits, recent_commands)}
    ]
    payload_size_kb = calculate_payload_size(messages)
    raw_response = ask(messages, json: true)
    parse_commit_plan_response(raw_response, payload_size_kb)
  end

  private

  MAX_CONTENT_SIZE_CHARS = 200 * 1024
  USER_CONTENT_SECTIONS = [
    {
      type: :static,
      key: :cli_hint,
      optional: true,
      template: "Here are hints or preferences from the user:\n\n%s\n"
    },
    {
      type: :static,
      key: :status_output,
      optional: false,
      template: "Here is the git status:\n\n%s\n"
    },
    {
      type: :diff,
      label: "(1) Uncommitted changes — SOURCE OF TRUTH for commit messages (git diff vs HEAD, or empty tree with no commits yet):",
      key: :uncommitted_diff_output
    },
    {
      type: :diff,
      label: "(2) Already on branch vs origin/HEAD — context only, not for message wording (git diff origin/HEAD...):",
      key: :mr_diff_output
    },
    {
      type: :static,
      key: :recent_commits,
      optional: false,
      template: "Here are the last 15 git commit one-line messages (most recent first):\n\n%s\n"
    },
    {
      type: :static,
      key: :recent_commands,
      optional: true,
      template: "Here are the last 5 shell commands from the user's terminal history " \
        "(most recent last):\n\n%s\n"
    }
  ].freeze

  def append_section(parts, current_size_chars, max_size_chars, text)
    return current_size_chars if text.empty? || current_size_chars + text.length > max_size_chars

    parts << text
    current_size_chars + text.length
  end

  def append_static_section(parts, current_size_chars, max_size_chars, value, config)
    return current_size_chars if config[:optional] && value.empty?

    append_section(parts, current_size_chars, max_size_chars, format(config[:template], value))
  end

  def append_labeled_diff_section(parts, current_size_chars, max_size_chars, section, data)
    diff_output = data.fetch(section[:key], "").to_s
    return current_size_chars if diff_output.to_s.strip.empty?

    diff_text = "#{section[:label]}\n\n"
    remaining = max_size_chars - current_size_chars - diff_text.length
    if remaining <= 0
      parts << "#{diff_text}(Diff truncated: exceeds #{MAX_CONTENT_SIZE_CHARS} chars limit)\n"
      return current_size_chars
    end
    truncated = truncate_diff_at_newline(diff_output, remaining)
    diff_text += truncated
    if truncated.length < diff_output.length
      diff_text += "\n\n... (diff truncated at #{MAX_CONTENT_SIZE_CHARS} chars limit)\n"
    end
    parts << diff_text
    current_size_chars + diff_text.length
  end

  def truncate_diff_at_newline(diff_output, max_chars)
    return "" if max_chars <= 0
    return diff_output if diff_output.length <= max_chars

    slice = diff_output[0, max_chars]
    last_newline = slice.rindex("\n")
    return diff_output[0, last_newline + 1] unless last_newline.nil?

    slice
  end

  def append_configured_section(parts, current_size_chars, max_size_chars, section, data)
    return append_labeled_diff_section(parts, current_size_chars, max_size_chars, section, data) if section[:type] == :diff

    append_static_section(
      parts,
      current_size_chars,
      max_size_chars,
      data.fetch(section[:key], "").to_s,
      section
    )
  end

  def append_user_content_sections(parts, max_size_chars, data)
    current_size_chars = 0
    USER_CONTENT_SECTIONS.each do |section|
      current_size_chars = append_configured_section(parts, current_size_chars, max_size_chars, section, data)
    end
    current_size_chars
  end

  def build_user_content(status_output, mr_diff_output, uncommitted_diff_output, cli_hint, recent_commits,
    recent_commands)
    data = {
      status_output: status_output,
      mr_diff_output: mr_diff_output,
      uncommitted_diff_output: uncommitted_diff_output,
      cli_hint: cli_hint,
      recent_commits: recent_commits,
      recent_commands: recent_commands
    }
    parts = []
    append_user_content_sections(parts, MAX_CONTENT_SIZE_CHARS, data)
    parts.join("\n")
  end

  def parse_commit_plan_response(raw_response, payload_size_kb)
    [raw_response.strip, extract_json_object(raw_response)].each do |candidate|
      next unless candidate

      begin
        return Oj.load(candidate)
      rescue Oj::ParseError
        next
      end
    end

    puts "Failed to parse model response as JSON.".red
    puts "Payload size: #{payload_size_kb} KB".yellow
    puts "Raw response:\n#{raw_response}".red
    exit 1
  end

  def extract_json_object(text)
    start = text.index("{")
    finish = text.rindex("}")
    text[start..finish] if start && finish && finish > start
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
      - (1) Uncommitted changes: unified diff of working tree and index vs HEAD, or vs the empty tree if there is no commit yet (same as `git diff HEAD` after the first commit; `git add -N` is respected) — **sole source of truth** for what each commit `message` and `quality_assessment.explanation` describe; these hunks are the ONLY files eligible to be committed
      - (2) Already on branch: unified diff of **committed** changes vs origin/HEAD (`git diff origin/HEAD...`) — **context only** so you do not assign already-committed paths to new commits; **never** copy themes, bug titles, or technical topics from this diff into new commit messages unless the same topic appears in (1) for the files you are committing
      - optional user-provided hints or preferences from the command line
      - last 15 git commit one-line messages — **style only** (language, JIRA bracket format, conventional-commit shape); **never** reuse their subject-matter or problem description for new messages unless (1) clearly shows that same work continues
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
      - Analyze the status and **section (1) uncommitted diff** to infer logical groups of changes (by feature, bugfix, refactor, docs, tests, etc.).
      - **Commit message accuracy (critical)**: Every substantive word in each `message` and in `quality_assessment.explanation` MUST match a change visible in section (1) for the files in that commit. If section (1) does not show a topic (e.g. a library, subsystem, or bug class), that topic MUST NOT appear in new commit text — even if section (2) or recent commit titles discuss it.
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
      - Create commit messages consistent with the **format and language** of recent commit messages, not their **topics** (unless section (1) proves the same work).
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
          - A one-line, conventional-style commit message (no trailing period). **Prioritize business and system value**: state the problem solved, risk removed, or capability delivered (what stakeholders or production gain). Use implementation detail (framework, pattern, file type) only when there is no clearer outcome-level summary.
          - **Language principles**:
            - **English**: Use imperative verbs - "add X", "fix Y", "remove Z"
            - **Russian**: Use verbal nouns - "добавление X", "исправление Y", "удаление Z"
            - **Other languages**: Follow standard commit message conventions for that language
          - **Universal principles**:
            - Prefer **why it matters** (correct data, fewer incidents, safer releases, clearer behavior) over **how it was coded**
            - Be specific; avoid vague terms like "optimization", "improvement", "fix issues" without naming the effect
            - Technical jargon is fine in the subject only when it *is* the change (e.g. dependency bump); otherwise lead with impact
          - A list of file paths to include in that commit
        - **Commit Ordering**: Organize commits to follow Test-Driven Development principles:
          - When implementing a new feature or fixing a bug, place test commits before implementation commits
          - If the original development followed TDD (tests written before code), preserve this sequence in commit ordering
          - Example ordering: "add failing tests for user authentication" → "implement user authentication logic"
          - When tests were written after implementation, group implementation and tests together in a single commit
          - Every changed file from status must appear in **exactly one** commit OR in excluded_files — never in more than one commit
          - **Only files present in `git status` output are eligible for commits.** Files that appear only in the branch-vs-origin diff (2) are already committed — do NOT include them in any commit's file list
          - Extract complete file paths from status output by taking the full path after status flags (e.g., from "new file:   manifest.json", extract "manifest.json")
          - Never truncate or modify file paths - always use the complete filename including extensions
          - Prefer coherent commits over many tiny ones
        - **File Exclusion Rules**:
          - **Do not exclude source code for truncation**: Never put source code files (e.g. .c, .h, .mm, .rb, .py, .js, .swift) in excluded_files solely because the diff was truncated or incomplete. Include them in the appropriate commit(s) using the partial diff when present.
          - **schema.rb**: Exclude from commits if there are no database migration files in the changeset. Migration files are typically in `db/migrate/` directory with timestamps.
          - **Temporary and debug files**: Exclude from commits if changes are clearly temporary or debug-only, such as:
            - Files in `tmp/` directory
            - Files with `.log`, `.tmp`, `.temp`, `.bak`, `.swp`, `.swo` extensions
            - Debug console output added with `puts`, `p`, `pp`, or `debugger` statements that are not part of actual functionality
            - Test stub files in `spec/stubs/`, `test/stubs/`, `test/fixtures/` when unrelated to test code changes
          - For each excluded file, provide a clear reason in the excluded_files section.
        - **Overall impact assessment** (`quality_assessment` in JSON — same schema, value-focused wording):
          - Set `direction` to increased / decreased / unchanged from the perspective of **overall code and product quality** (reliability, security, maintainability, correctness) — not from "more elegant code" alone. Bug fixes, crash prevention, and new safety checks **increase** quality. Regressions, removed safeguards, or introduced defects **decrease** quality.
          - In `explanation`, **lead with the outcome**: what becomes safer, more correct, more reliable, or easier for the team or users, and what failure mode is eliminated. Treat technical edits (RSpec helpers, refactors, typing) as **evidence** in a second sentence, not as the headline.
          - Do **not** open with low-level mechanics (e.g. "Changing let_it_be to let…") unless the diff is purely internal with no user-facing story — then still state **what correctness or stability** is preserved or improved.
          - Keep to 2–3 sentences maximum; no bullet lists inside the string.
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
          "explanation": "2-3 sentences: quality/reliability outcome first; technical detail only to support that story"
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
      If impact is neutral or unclear from the diff, use "unchanged" for direction and say so briefly in `explanation`.

      Do not include any text outside of the JSON.
    HEREDOC
  end
end
