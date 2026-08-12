# frozen_string_literal: true

# Static system rules and dynamic project keywords for ag_gpt.rb.
# File-name keywords belong on the user turn so the system prompt stays
# stable when the working tree changes.
module AgPrompt
  module_function

  def search_system_instruction
    <<~HEREDOC
      Task: Use `ag` (The Silver Searcher) to search through the software repository and answer the user's request by outputting a single shell command.

      High-level behavior:
      - Construct a plain `ag` command that directly searches for the most relevant pattern(s) based on the user's request.
      - Keep this `ag` usage simple and broad so you do not accidentally miss real results.
      - Do NOT use any additional Unix text-processing tools (no awk/sed/cut/sort/uniq/tr/grep/etc.). Only `ag` is allowed.

      The user message includes project keywords and file-name tokens (BFS-ordered by directory depth).

      Repository Navigation Strategy:
      - Prefer breadth-first traversal of directories (shallow paths first) when reasoning about where code might live.
      - When the user asks for a specific module, class, or file by name (not by its text content):
        * Infer likely file paths using common conventions (e.g. snake_case for Ruby, matching directory names, etc.).
        * Use `ag -g` (file name search) with an appropriate pattern to locate candidate files.
        * Example:
          - User: "find UserService module"
            Command: ag -g 'UserService' .
          - User: "find user_service.rb"
            Command: ag -g 'user_service\\.rb' .

      Content Search:
      - Default behavior:
        * Use a plain `ag` search that is likely to capture all relevant occurrences.
        * Example:
          - User: "List all widget types"
            ag --ignore '*.min.*' 'widget' .
        * This ensures you do not miss real results due to overly strict parsing.
      - Do NOT append any pipelines or additional commands. Only a single `ag` invocation is allowed.

      Command Formation:
      - If the request is primarily about locating files/modules by name:
        * Prefer `ag -g 'name_pattern' .`
      - Otherwise (text/content based search):
        * Construct the `ag` command to search, excluding minified files:
          ag --ignore '*.min.*' 'search_regex' .
      - Always:
        * Escape regex metacharacters in literal file names where appropriate (e.g. `.` -> `\\.`).
        * Keep the command on a single line.
        * Use `.` as the search root unless the user clearly specifies another directory.

      Output:
      - Provide only the complete shell command without any other text.
      - Do not wrap the command in backticks or quotes.
    HEREDOC
  end

  def interpret_system_instruction
    <<~HEREDOC
      You are helping a developer understand the results of running `ag` (The Silver Searcher) on their codebase.

      The user asked a question about their code. An `ag` search was run to find relevant matches.
      You will be given:
      - The user's original natural-language question.
      - The raw `ag` output (file:line:matched text).

      Your task:
      - Interpret the `ag` results in the context of the user's question.
      - Explain what in the codebase appears relevant to their question.
      - Summarize key files, lines, and patterns that matter.
      - If appropriate, infer how the code works or where they might need to look next.
      - If the results seem incomplete or noisy, say so and explain why.

      Be concise but specific. Refer to files and line numbers when helpful.
    HEREDOC
  end

  def search_messages(user_instruction, project_keywords:)
    [
      {role: 'system', content: search_system_instruction},
      {role: 'user', content: search_user_content(user_instruction, project_keywords)}
    ]
  end

  def interpret_messages(user_instruction, ag_output)
    [
      {role: 'system', content: interpret_system_instruction},
      {role: 'user', content: <<~HEREDOC}
        User question:
        #{user_instruction}

        ag output:
        #{ag_output}
      HEREDOC
    ]
  end

  def search_user_content(user_instruction, project_keywords)
    <<~HEREDOC
      Project keywords and file-name tokens (BFS-ordered by directory depth):
      #{project_keywords}

      Request:
      #{user_instruction}
    HEREDOC
  end
end
