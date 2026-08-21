# frozen_string_literal: true

# LLM client that writes a Markdown explanation of git working-tree changes.
class GitExplainer
  include AgentsFileHandler

  def initialize(model: nil, debug: false)
    @client = OpenrouterClient.new(model: model, debug: debug,
      progress_title: "Analyzing changes")
  end

  def ask(prompts, json: false)
    @client.ask(prompts, json: json)
  end

  def explain_changes(status_output, diff_output, recent_commits, recent_commands)
    ask([
      {role: "system", content: system_instruction},
      {role: "user", content: build_user_content(status_output, diff_output, recent_commits, recent_commands)}
    ])
  end

  private

  def build_user_content(status_output, diff_output, recent_commits, recent_commands)
    content_parts = [
      "Here is the git status:\n#{status_output.to_s.strip}\n\n",
      "Here is the git diff for all changes:\n#{diff_output.to_s.strip}\n\n",
      "Here are the last 15 git commit one-line messages (most recent first):\n#{recent_commits.to_s.strip}\n\n"
    ]

    unless recent_commands.empty?
      content_parts << "Here are the last 5 shell commands from the user's terminal history " \
        "(most recent last):\n\n#{recent_commands}\n"
    end

    content_parts.join("\n")
  end

  def system_instruction
    <<~HEREDOC
      You are a tool that analyzes git changes and creates comprehensive explanations in Markdown format.

      Input:
      - `git status --porcelain --branch` output (compact format showing current branch name, added, modified, deleted, renamed, untracked files)
      - unified git diff for all changes (including new files)
      - last 15 git commit one-line messages to understand project context
      - last 5 shell commands from the user's terminal history for additional context

      Porcelain v1 format guide:
      - `## branch...upstream` - branch info line
      - ` M file.rb` - modified, not staged
      - `M  file.rb` - staged for commit
      - `MM file.rb` - modified and staged
      - `?? file.rb` - untracked
      - `R100 old.rb -> new.rb` - renamed (keep both names)

      Task:
      Analyze the changes and create a technical developer-focused Markdown explanation with these sections:

      # [Clear, descriptive title summarizing the main changes]

      ## 1. The Goal
      - Primary technical purpose and objectives of these changes
      - What problem or requirement this addresses
      - Expected outcomes and benefits

      ## 2. Use Cases
      - Specific scenarios where these changes will be applied
      - User workflows or developer interactions enabled
      - Integration points with existing functionality
      - Edge cases and special conditions handled

      ## 3. Developer Journey
      - **Problem Understanding**: How the core issue or requirement was identified
      - **Initial Approach**: First ideas and why they worked or didn't work
      - **Iterative Refinement**: Step-by-step evolution of the solution with code examples
        - **Example Data Structures**: Illustrate the journey with concrete examples of:
          - Models/Entities being modified (e.g., User, Product, Order objects with actual data)
          - API request/response payloads showing before/after states
          - Database schema changes with sample records
          - Configuration structures and their transformations
      - **Key Decisions**: Critical technical choices and their rationale
      - **Implementation Details**: Specific code patterns and techniques used
      - **Testing Strategy**: How the solution was verified to work correctly
      - **Lessons Learned**: What was discovered during the development process

      ## 4. Technical Implementation
      - **Code Changes**: Detailed analysis of each modified file with specific line numbers
      - **API Changes**: New methods, modified signatures, breaking changes
      - **Dependencies**: New gems, imports, or external dependencies
      - **Before/After Comparisons**: Show specific code changes with explanations
      - **Logic Flow**: How execution flow is affected
      - **Performance Implications**: Any performance considerations
      - **Error Handling**: Changes to exception handling, validation

      ## 5. Testing Recommendations
      - Analyze the current project structure and existing test patterns
      - Determine appropriate testing framework (Minitest vs RSpec) based on Ruby conventions
      - Identify which components need unit tests vs integration tests vs end-to-end tests
      - Consider testing approach for git operations, API interactions, and display functionality
      - Recommend specific test tools for mocking external dependencies (HTTP, git commands)
      - Suggest test organization structure that fits the current codebase layout

      ## 6. Key Takeaways
      - Most important technical points developers need to remember (3-7 bullet points)
      - Critical changes that affect daily work
      - Essential actions or considerations
      - Migration path for existing code
      - Common pitfalls or things to watch out for

      ## 7. Prompts for Further Development
      - 3-5 concise prompt starters for LLM agents to apply recommended changes
      - Cover code implementation, tests, integrations, and documentation updates
      - Keep prompts short, direct, and action-oriented

      Format Requirements:
      - Use proper Markdown with code blocks showing actual diff content
      - Include specific file paths and line numbers (e.g., `src/models/user.rb:45-52`)
      - Show actual code snippets with syntax highlighting
      - Focus on technical implementation details, not business value
      - Be specific about what developers need to know to work with this code
      - Include practical examples and usage patterns
      - **IMPORTANT**: Only include sections that have meaningful content. Skip sections with "None", "No changes", "Not applicable", or similar empty responses. Keep the report focused and easy to read.
    HEREDOC
  end
end
