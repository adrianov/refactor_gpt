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
# Lint and auto-correct Ruby code style (use bundle exec when the project has RuboCop in the Gemfile)
bundle exec rubocop -a

# Validate syntax
ruby -c path/to/file.rb
```

**RuboCop policy**: Fix all offenses in touched files; do not use `# rubocop:disable` or expand `.rubocop.yml` / todo excludes to hide violations (see `.cursor/rules/rubocop-no-suppress.mdc`).

**Note**: This project does not have automated tests. Manual testing involves running the individual scripts.

## Ruby Development Guidelines

When working with this codebase, follow these refactoring principles:

### Core Principles
- **Correctness**: Fix bugs, improve error handling, validate inputs
- **Readability**: Use clear names, follow Ruby conventions, meaningful methods
- **Simplicity**: Keep methods under 15 lines when possible, remove dead code
- **Consistency**: Follow idiomatic Ruby style and existing patterns
- **Behavior Preservation**: Never change functionality unless fixing bugs or explicitly requested
- **Refactor when it helps**: Do not hesitate to refactor when it improves code quality; apply the guidelines above even if it means broader changes.
- **Review comments**: When correcting review comments, make minimal changes; use `git diff master... path/to/file` to see current changes for the file and keep the diff small.

### LLM Instruction Optimization
When modifying LLM prompts or system instructions in AI-driven applications:
- **Improve user wording**: Enhance and optimize language rather than following user wording strictly
- **Use precise language**: Employ literal, unambiguous phrasing instead of vague or ambiguous terms
- **Optimize for clarity**: Ensure instructions are comprehensible to both native speakers and automated parsing systems
- **Structure for parsing**: Use consistent formatting (lists, bullet points, code blocks) that machines can parse reliably
- **Eliminate redundancy**: Remove repetitive or contradictory statements
- **Use explicit directives**: State requirements directly using imperative language - "must", "should", "always", "never"
- **Provide examples**: Include concrete examples when instructions are complex or potentially ambiguous

### File Conventions
- Script files follow the pattern `*_gpt.rb`
- Use shebang `#!/usr/bin/env ruby` at the top
- Keep dependencies minimal
- Follow existing error handling patterns
- Prefer HEREDOC for multiline strings over string concatenation

### Imports and Dependencies
- Use `require_relative` for local files: `require_relative "lib/openai_client"`
- External gems required: `httpx`, `oj`, `ruby-progressbar`, `colorize`, `shellwords`, `tty-box`, `tty-cursor` (superagent TUI)
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
- Place shared code in `lib/` directory
- Extract helper modules into separate files when they exceed reasonable size
- Maximum class/module length: 400 lines (extract to new classes/modules when approaching limit)
- Maximum ABC complexity metric: 17

### Comments
- Preserve existing comments unless they refer to code that has been changed or removed
- Do not add new comments unless explicitly requested
- Use comments only to explain complex business logic that cannot be made clear through code structure
- **Changed classes**: Add a short description comment above each class that you modify (one line describing the class purpose)
- **High ABC (assignment, branch, comparison) complexity**: When a class or method has a high ABC score or triggers complexity metrics (e.g. `Metrics/AbcSize`), add brief comments that explain the business logic for that class or method and for the most complex sections inside it. Prefer refactoring to reduce complexity; when complexity cannot be reduced further, document intent with comments so behavior remains understandable.

### Code Optimization
- **Inline single-use variables**: After each modification, inline variables that are used only once to improve readability and reduce unnecessary assignments
- Example: `result = some_calculation; return result` becomes `return some_calculation`

### Refactoring Unused and Dead Code
When refactoring code, systematically identify and remove unused and dead code while preserving all business logic:
- **Identify unused code**: Search for unused methods, variables, parameters, constants, and imports that are never referenced
- **Detect dead code**: Find unreachable code blocks, unreachable branches, and code paths that cannot execute
- **Verify before removal**: Before removing any code, confirm it is truly unused by:
  - Checking all call sites and references
  - Verifying it's not part of a public API or interface
  - Ensuring it's not used via metaprogramming or dynamic dispatch
  - Confirming it's not required for future functionality or backward compatibility
- **Preserve business logic**: Never remove code that implements business rules, validation logic, or domain-specific behavior, even if it appears unused
- **Extract before removing**: When extracting classes or modules, ensure all business logic is moved to appropriate locations before removing original code
- **Remove systematically**: Remove unused code in a single refactoring pass to avoid leaving partial removals that create confusion
- **Document removals**: When removing significant unused code, consider documenting why it was safe to remove (e.g., "Removed unused parameter after extracting to separate class")

### Safety
- Always request user confirmation before performing dangerous operations
- Create backups for non-git files before modification
- Handle network errors gracefully with appropriate retry logic
- Use explicit exit codes (0 for success, non-zero for failure)
- Shell-escape all user-provided paths using `Shellwords.escape` to prevent injection attacks
- Use `File::NULL` for discarding command output when redirecting to /dev/null

### Linting and Code Quality
- **Treat linter warnings seriously**: For any file or module you change, fix all Rubocop offenses reported in that file. Do not leave new or existing linter warnings in modified code.
- Git commit flow best-effort runs `bundle exec rubocop -a` then plain `rubocop -a` on changed Ruby paths; if both fail, planning continues (Bundler 4 ignores the old `BUNDLE_DISABLE_RUBY_VERSION_CHECK` escape)
- Ensure syntax is valid with `ruby -c` after modifications
- Follow Ruby style guides and existing code conventions
- Remove duplicate code and unused variables systematically
- Read files completely when fixing errors or adding new functionality to ensure complete context is preserved
- **Metric Violations**: When Rubocop detects Metric violations (e.g., `Metrics/AbcSize`, `Metrics/MethodLength`, `Metrics/ClassLength`, `Metrics/CyclomaticComplexity`, `Metrics/ModuleLength`), refactor by:
  - Extracting complex logic into smaller, focused methods
  - Breaking down large methods into logical units
  - Using guard clauses to reduce nested conditions
  - Extracting conditional logic into separate methods
  - Applying Single Responsibility Principle
  - Creating helper methods for repeated patterns
  - Ensure extracted methods have descriptive names that explain their purpose
  - Splitting large files into smaller, focused modules/classes when approaching 400-line limit
  - **Never disable Metrics/AbcSize inline**; adjust code or configuration instead.
  - When complexity remains high after refactoring (e.g. ABC score near the limit), add business-logic comments per the **High ABC complexity** rule under Comments.
