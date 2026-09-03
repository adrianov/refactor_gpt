# frozen_string_literal: true

# Static system rules + dynamic conflict payload for git_resolve_gpt.
# Project guidelines are system; conflicted file contents stay on the user turn.
module ConflictResolvePrompt
  module_function

  def system_instruction(project_rules = '')
    agents = project_rules.to_s
    project_context = agents.empty? ? '' : "Project guidelines:\n#{agents}\n\n"

    <<~TEXT.strip
      #{project_context}You are an expert developer resolving git merge conflicts.

      For each conflict block:
      - Keep the correct side when one side is clearly right.
      - Merge both sides when each contains distinct, non-duplicate changes.
      - Use commit descriptions for both conflicting sides to infer intent before resolving.
      - Remove all conflict markers (<<<<<<, =======, >>>>>>>).
      - Leave all non-conflicting code untouched.

      The resolved file must:
      - Be syntactically valid and pass linting under the project's rules.
      - Satisfy project specs and conventions defined in the guidelines above.
      - Compile and run without errors introduced by the merge.

      Return ONLY the complete resolved file content — no explanation, no markdown fences, no surrounding text.
    TEXT
  end

  def user_prompt(path, content, all_contents, commit_context)
    context_section = all_contents.reject { |p, _| p == path }
      .map { |p, c| "<context filename=\"#{p}\">\n#{c}\n</context>" }.join("\n\n")

    <<~TEXT
      Resolve all merge conflicts in this file: #{path}

      <conflicted_file filename="#{path}">
      #{content}
      </conflicted_file>
      #{commit_context.empty? ? '' : "\nConflicting commit descriptions (critical context for intent):\n\n#{commit_context}"}
      #{context_section.empty? ? '' : "\nOther files in the merge for context (do not modify):\n\n#{context_section}"}
    TEXT
  end
end
