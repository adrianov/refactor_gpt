# frozen_string_literal: true

require "oj"
require "colorize"

# Calls the LLM to produce a commit plan (commits, warnings, quality_assessment impact summary, excluded_files).
class CommitPlanClient
  include AgentsFileHandler

  # Single ceiling for commit-plan user message (static sections + one unified diff body); MR uses numstat only.
  COMMIT_PLAN_USER_PAYLOAD_CHAR_LIMIT = 200 * 1024

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
      label: "(1) Uncommitted changes — SOURCE OF TRUTH for commit messages " \
             "(git diff HEAD, includes staged and unstaged):",
      key: :uncommitted_diff_output
    },
    {
      type: :static,
      key: :mr_numstat_output,
      optional: true,
      template: "(2) Already on branch vs origin/HEAD — context only (not for commit message wording). " \
                "Per-file insert/delete counts from `git diff --numstat -w origin/HEAD...` " \
                "(no unified patch for already-committed branch work):\n\n%s\n"
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

  # Single payload ceiling: uncommitted diff budget is what remains after all static sections (incl. MR numstat).
  def self.diff_body_budgets_chars(cli_hint:, status_output:, recent_commits:, recent_commands:, mr_numstat: "")
    data = {
      cli_hint: cli_hint.to_s,
      status_output: status_output.to_s,
      recent_commits: recent_commits.to_s,
      recent_commands: recent_commands.to_s,
      mr_numstat_output: mr_numstat.to_s
    }
    static_chars = sum_static_section_lengths(data)
    header_chars = sum_diff_header_lengths
    join_slack = [USER_CONTENT_SECTIONS.size - 1, 0].max
    remaining = COMMIT_PLAN_USER_PAYLOAD_CHAR_LIMIT - static_chars - header_chars - join_slack
    remaining = remaining.positive? ? remaining : 0
    {uncommitted: remaining}
  end

  def self.sum_static_section_lengths(data)
    USER_CONTENT_SECTIONS.sum do |sec|
      next 0 unless sec[:type] == :static
      next 0 if sec[:optional] && data.fetch(sec[:key]).strip.empty?

      format(sec[:template], data.fetch(sec[:key])).length
    end
  end

  def self.sum_diff_header_lengths
    USER_CONTENT_SECTIONS.sum do |sec|
      sec[:type] == :diff ? "#{sec[:label]}\n\n".length : 0
    end
  end

  private_class_method :sum_static_section_lengths, :sum_diff_header_lengths

  def initialize(model: nil, debug: false)
    @client = OpenAiClient.new(model: model, debug: debug,
      progress_title: "Planning commits".cyan)
  end

  def ask(prompts, json: false)
    @client.ask(prompts, json: json)
  end

  def commit_plan(status_output, mr_numstat_output, uncommitted_diff_output, cli_hint, recent_commits,
    recent_commands)
    messages = [
      {role: "system", content: system_instruction},
      {role: "user",
       content: build_user_content(status_output, mr_numstat_output, uncommitted_diff_output, cli_hint,
         recent_commits, recent_commands)}
    ]
    payload_size_kb = calculate_payload_size(messages)
    raw_response = ask(messages, json: true)
    parse_commit_plan_response(raw_response, payload_size_kb)
  end

  private

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
    return current_size_chars if diff_output.strip.empty?

    combined = "#{section[:label]}\n\n#{diff_output}"
    append_section(parts, current_size_chars, max_size_chars, combined)
  end

  def append_configured_section(parts, current_size_chars, max_size_chars, section, data)
    if section[:type] == :diff
      return append_labeled_diff_section(parts, current_size_chars, max_size_chars, section, data)
    end

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

  def build_user_content(status_output, mr_numstat_output, uncommitted_diff_output, cli_hint, recent_commits,
    recent_commands)
    data = {
      status_output: status_output,
      mr_numstat_output: mr_numstat_output,
      uncommitted_diff_output: uncommitted_diff_output,
      cli_hint: cli_hint,
      recent_commits: recent_commits,
      recent_commands: recent_commands
    }
    parts = []
    append_user_content_sections(parts, COMMIT_PLAN_USER_PAYLOAD_CHAR_LIMIT, data)
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
      - (1) Uncommitted changes: unified diff of working tree and index vs HEAD (`git diff HEAD`; `git add -N` is respected) — **sole source of truth** for what each commit `message` and `quality_assessment.explanation` describe; these hunks are the ONLY files eligible to be committed; staged files are visible in `git status` with a non-space first column (e.g. `M `, `A `) and should be treated as intentionally pre-selected by the user
      - (2) When `origin/HEAD` exists and this section is present: **numstat only** for work already committed on this branch vs merge-base with `origin/HEAD` (`git diff --numstat -w origin/HEAD...`). Each non-binary line is: `<added TAB deleted TAB path>` (counts are lines added/removed). **There is no unified diff here** — you cannot inspect patch text or exact edits for that already-committed work; use (2) only to see **which paths** already diverge from origin and **approximate size**. **When this section is absent**, assume no remote tracking ref was available — treat as “no branch-vs-origin snapshot.” **Context only**: paths that appear **only** in (2) are **not** eligible for new commits from (1); **never** base new commit messages on themes visible only in (2) unless the same topic appears in (1).
      - optional user-provided hints or preferences from the command line
      - last 15 git commit one-line messages — **style only** (language, JIRA bracket format, conventional-commit shape); **never** reuse their subject-matter or problem description for new messages unless (1) clearly shows that same work continues
      - last 5 shell commands from the user's terminal history to give you extra context

      `git diff --numstat` (section 2): added/deleted are line counts (use `-` for binary files when Git prints that form). Do not infer code, syntax, or logic from counts alone.

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
      - Analyze the status and **section (1) uncommitted diff** to infer logical groups of changes (by feature, bugfix, refactor, docs, tests, etc.). Files already staged (non-space first column in `git status`) are pre-selected by the user and should be grouped into an early commit. **Code-level assessment and line-specific warnings must be grounded in section (1)** — section (2) is counts only.
      - **Commit message accuracy (critical)**: Every substantive word in each `message` and in `quality_assessment.explanation` MUST match a change visible in section (1) for the files in that commit. If section (1) does not show a topic (e.g. a library, subsystem, or bug class), that topic MUST NOT appear in new commit text — even if section (2) numstat, file names there, or recent commit titles suggest a story.
      - **Code Assessment**: Review all changes for the following categories of issues:
        - **Correctness**: syntax errors, typos, logic errors, off-by-one, incorrect implementations
        - **Undefined references**: calls to deleted, moved, or undefined methods, functions, variables, or constants
        - **Dead code**: unreachable branches, unused methods, variables, or constants left after refactoring
        - **Runtime risks**: potential exceptions, nil dereferences, type mismatches, security vulnerabilities, unsafe practices
        - **Performance**: anti-patterns, unnecessary allocations, inefficient loops
        - **DRY violations**: duplicated logic or data that should be extracted into a shared abstraction
        - **SOLID violations**:
          - *Single Responsibility*: a class or module handles too many unrelated concerns and should be split
          - *Open/Closed*: logic requires modifying existing code instead of extending it
          - *Liskov Substitution*: a subclass breaks the contract of its parent
          - *Interface Segregation*: a class is forced to implement methods it does not need
          - *Dependency Inversion*: high-level code depends directly on low-level implementation details
        - **Unnecessary complexity**:
          - Variables assigned once and used only in the next expression — should be inlined
          - Helper methods that are one line long and called only once — should be inlined into the caller
          - Classes or modules so small they add indirection without value — consider merging into the caller
        - **Responsibility overload**: a class or module accumulates too many responsibilities and should be divided into focused units
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
          - **Only files present in `git status` output are eligible for commits.** Paths that show up **only** in section (2) numstat (already on the branch vs origin) are already committed — do NOT include them in any new commit's file list.
          - Extract complete file paths from status output by taking the full path after status flags (e.g., from "new file:   manifest.json", extract "manifest.json")
          - Never truncate or modify file paths - always use the complete filename including extensions
          - Prefer coherent commits over many tiny ones
        - **File Exclusion Rules**:
          - **Do not exclude source code for omission**: Never put source code files (e.g. .c, .h, .mm, .rb, .py, .js, .swift) in excluded_files solely because the diff was omitted or incomplete under payload limits. Include them in the appropriate commit(s) using the partial diff when present.
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
        - For each detected issue, produce a warning entry with:
          - The affected file path
          - A `category` from: correctness | undefined_reference | dead_code | runtime_risk | performance | dry | solid | complexity | responsibility
          - A precise, actionable description: name the specific symbol, pattern, or construct involved; state what is wrong and what should be done instead
          - A probability (0.0–1.0) reflecting confidence this is a real issue (omit near-zero confidence items)
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
            "category": "correctness",
            "description": "`index` starts at 1 instead of 0 — last element is never processed; change to `0..arr.length - 1`",
            "probability": 0.85,
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
