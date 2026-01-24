# RefactorGPT Tools

A collection of Ruby scripts that leverage GPT-5.1 to help with code refactoring, searching, and bash command generation.

## Project Overview

RefactorGPT Tools provides command-line utilities for:
- **Code refactoring** (`refactor_gpt.rb`) - Automated code improvement while preserving functionality
- **Code searching** (`ag_gpt.rb`) - Natural language interface for searching codebases using The Silver Searcher
- **Bash command generation** (`bash_gpt.rb`) - Generate and execute bash commands from natural language
- **General assistance** (`ask_gpt.rb`) - Terminal-based AI assistant for questions and explanations
- **Git commit planning** (`git_commit_gpt.rb`) - Create structured git commits based on changes

## Build/Lint/Test Commands

```bash
# Lint and auto-correct Ruby code style
rubocop -a

# Validate syntax
ruby -c path/to/file.rb
```

**Note**: This project does not have automated tests. Manual testing involves running the individual scripts.

## Ruby Development Guidelines

When working with this codebase, follow these refactoring principles:

### Core Principles
- **Correctness**: Fix bugs, improve error handling, validate inputs
- **Readability**: Use clear names, follow Ruby conventions, meaningful methods
- **Simplicity**: Keep methods under 15 lines when possible, remove dead code
- **Consistency**: Follow idiomatic Ruby style and existing patterns
- **Behavior Preservation**: Don't change functionality unless fixing bugs or explicitly requested

### LLM Instruction Optimization
When modifying LLM prompts or system instructions in AI-driven applications:
- **Don't follow user wording strictly**: Improve and optimize the language
- **Make it literal**: Use precise, unambiguous language instead of vague phrasing
- **Optimize for clarity**: Ensure instructions are easily understood by both native speakers and computer parsing
- **Structure for parsing**: Use consistent formatting (lists, bullet points, code blocks) that machines can parse reliably
- **Remove redundancy**: Eliminate repetitive or contradictory statements
- **Use explicit directives**: Be direct about requirements - "must", "should", "always", "never"
- **Examples**: Include concrete examples when the instruction is complex or ambiguous

### File Conventions
- Script files follow the pattern `*_gpt.rb`
- Use shebang `#!/usr/bin/env ruby` at the top
- Keep dependencies minimal
- Follow existing error handling patterns
- Prefer HEREDOC for multiline strings over string concatenation

### Imports and Dependencies
- Use `require_relative` for local files: `require_relative "lib/openai_client"`
- External gems required: `httpx`, `oj`, `ruby-progressbar`, `colorize`, `shellwords`
- Use `rbconfig` for OS detection in cross-platform scripts
- Use `reline` for interactive CLI input

### Naming Conventions
- **Classes**: PascalCase (`OpenAiClient`, `FileProcessor`)
- **Modules**: PascalCase (`AgentsFileHandler`, `Utility`)
- **Methods**: snake_case (`ask`, `refactor`, `build_system_instruction`)
- **Constants**: UPPER_SNAKE_CASE (`DEFAULT_MODEL`, `REQUEST_TIMEOUT`, `CODE_EXTENSIONS`)
- **Instance variables**: `@variable_name`
- **Local variables**: snake_case

### Formatting and Style
- Always include `# frozen_string_literal: true` as the first line
- Maximum line length: 120 characters
- Use 2-space indentation (Ruby standard)
- Prefer HEREDOC (`<<~HEREDOC`) for multi-line strings
- Use squiggly HEREDOC to strip leading whitespace
- Prefer single quotes for strings unless interpolation is needed
- Use `%w[]` for word arrays: `%w[.rb .py .js]`
- Use `%i[]` for symbol arrays: `%i[search_mode debug_mode]`

### Error Handling
- Define custom error classes inheriting from StandardError
- Use `rescue SystemCallError => e` for file operations
- Check `$?.success?` after system commands
- Use explicit exit codes (0 for success, 1 for failure)
- Validate user input before processing
- Gracefully handle network errors (HTTPX::Error)
- Handle JSON parsing errors (Oj::ParseError)

### File Structure
- Keep main scripts in root directory with `_gpt.rb` suffix
- Shared code in `lib/` directory
- Helper modules in separate files
- Maximum class/module length: 400 lines
- Maximum ABC complexity metric: 17

### Comments
- Preserve existing comments unless they refer to changed code
- Don't add new comments unless explicitly requested
- Use comments only for complex business logic

### Code Optimization
- **Inline single-use variables**: After each modification, inline variables that are used only once to improve readability and reduce unnecessary assignments
- Example: `result = some_calculation; return result` becomes `return some_calculation`

### Safety
- Always ask for confirmation before dangerous operations
- Create backups for non-git files
- Handle network errors gracefully
- Use appropriate exit codes
- Shell-escape all user-provided paths with `Shellwords.escape`
- Use `File::NULL` for discarding command output

### Linting and Code Quality
- Always run `rubocop -a` to auto-correct Ruby style issues before committing changes
- Ensure syntax is valid with `ruby -c` after modifications
- Follow Ruby style guides and existing code conventions
- Remove duplicate code and unused variables
- Read files as whole when fixing errors or adding new functionality to ensure complete context is preserved
- **Metric Violations**: When Rubocop detects Metric violations (e.g., `Metrics/AbcSize`, `Metrics/MethodLength`, `Metrics/ClassLength`, `Metrics/CyclomaticComplexity`, `Metrics/ModuleLength`), refactor by:
  - Extracting complex logic into smaller, focused methods
  - Breaking down large methods into logical units
  - Using guard clauses to reduce nested conditions
  - Extracting conditional logic into separate methods
  - Applying Single Responsibility Principle
  - Creating helper methods for repeated patterns
  - Ensure extracted methods have descriptive names that explain their purpose
  - Splitting large files into smaller, focused modules/classes when approaching 400-line limit
