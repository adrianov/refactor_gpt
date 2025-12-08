# RefactorGPT Tools Project

This is a collection of Ruby scripts that leverage GPT-5.1 to help with code refactoring, searching, and bash command generation.

## Project Overview

RefactorGPT Tools provides command-line utilities for:
- **Code refactoring** (`refactor_gpt.rb`) - Automated code improvement while preserving functionality
- **Code searching** (`ag_gpt.rb`) - Natural language interface for searching codebases using The Silver Searcher
- **Bash command generation** (`bash_gpt.rb`) - Generate and execute bash commands from natural language
- **General assistance** (`ask_gpt.rb`) - Terminal-based AI assistant for questions and explanations
- **Git commit planning** (`git_commit_gpt.rb`) - Create structured git commits based on changes

## Project Structure

- `refactor_gpt.rb` - Main refactoring tool with comprehensive code analysis and improvement
- `ag_gpt.rb` - Natural language code search using The Silver Searcher (`ag`)
- `bash_gpt.rb` - Bash command generation with safety confirmations
- `ask_gpt.rb` - General-purpose AI assistant for terminal use
- `git_commit_gpt.rb` - Git commit planning and execution helper
- `.env.example` - Environment variable template for OpenAI API configuration

## Ruby Development Guidelines

When working with this codebase, follow these refactoring principles unless explicitly overridden by user instructions:

### 1. Correctness & Robustness
- Identify and fix bugs or obvious mistakes
- Improve error handling where it is clearly insufficient or unsafe
- Prefer failing fast with clear messages over silent failures
- Validate environment variables and API responses
- Handle network timeouts and connection errors gracefully
- When making bug fixes or applying specific requested changes, keep the diff as small as reasonably possible in terms of changed lines

### 2. Readability & Naming
- Use clear, descriptive names for variables, methods, and classes
- Avoid unnecessary abbreviations unless they are domain-standard
- Follow Ruby naming conventions (snake_case for variables/methods, CamelCase for classes)
- Use meaningful method and variable names that describe their purpose

### 3. Structure & Size
- Prefer small, focused methods under 15 lines when possible
- Where it improves clarity, extract helper methods instead of enforcing arbitrary line limits
- Keep lines reasonably short (aim for <= 100 characters), but do not harm readability just to satisfy a strict width
- Use Ruby's built-in methods and idioms effectively
- Do not harm readability just to satisfy a strict width limit

### 4. Simplicity
- Simplify complex conditionals and branching where possible
- Remove dead code and unnecessary indirection
- Inline variables that are used only once when it improves clarity
- Avoid over-engineering simple problems

### 5. Style & Consistency
- Follow idiomatic Ruby style (Ruby community conventions)
- Keep formatting consistent with the surrounding code
- Use Ruby's built-in enumerable methods instead of manual loops when appropriate
- Follow the existing code patterns in the project

### 6. Comments & Documentation
- Preserve all existing comments verbatim unless they refer to code you significantly change or a TODO you implement
- Do not add new comments unless the user explicitly asks for them
- Use comments to explain complex business logic or non-obvious implementation details
- Strictly preserve existing comments unless implemented TODOs or changed code fragment business logic, if not asked otherwise

### 7. Behavior Preservation
- Preserve existing business logic and external behavior unless there is a clear bug or the user explicitly requests a change
- When you must change behavior to fix a bug, keep the change as small and local as possible
- Maintain backward compatibility for command-line interfaces and configuration

### 8. TODOs
- Implement TODOs only if they are fully specified and safe to complete without guessing about missing requirements
- If a TODO is ambiguous, leave it in place and do not invent behavior
- Consider the impact on existing users and workflows before implementing TODOs

### 9. Default Behavior
- Do not change code behavior unless the user specifically asks for it or a change is required to fix a clear bug
- When refactoring, focus on improving code quality without changing functionality
- Respect the existing command-line interfaces and user expectations

## File Conventions

- Script files follow the pattern `*_gpt.rb` (e.g., `refactor_gpt.rb`, `ag_gpt.rb`)
- Use shebang `#!/usr/bin/env ruby` at the top of executable scripts
- Keep dependencies minimal and well-documented
- Follow the existing error handling patterns for API calls and file operations



## PR Analysis and Warning Fixes

When analyzing pull requests and fixing warnings, follow this systematic approach:

### PR Analysis Process
1. **Get PR diff from master**: Use `git diff main...HEAD` or `git diff master...HEAD` to analyze all changes in the current PR
2. **Comprehensive warning detection**: Analyze the diff for potential issues similar to `git_commit_gpt.rb` warning system:
   - Redundant code blocks and duplicate logic
   - Unnecessary function calls or process executions
   - Potential performance issues
   - Logic errors and edge cases
   - Security vulnerabilities
   - Code style inconsistencies

### Warning Categories
- **High Priority (0.8-1.0 probability)**: Clear bugs, security issues, performance problems
- **Medium Priority (0.5-0.7 probability)**: Code smells, maintainability issues, potential edge cases
- **Low Priority (0.1-0.4 probability)**: Style issues, minor optimizations

### Fix Implementation Strategy
1. **Confirm the issue exists**: Verify the warning by examining the actual code
2. **Assess impact**: Determine if the fix is safe and won't break existing functionality
3. **Make minimal changes**: Fix the specific issue without over-engineering
4. **Preserve behavior**: Ensure the fix doesn't change the external behavior of the code
5. **Test if possible**: Run available tests or basic functionality checks

### Automated Fix Guidelines
- **Duplicate code**: Remove redundant blocks and consolidate logic
- **Performance issues**: Eliminate unnecessary process calls and optimize algorithms
- **Logic errors**: Fix incorrect conditionals, loop bounds, and data handling
- **Style issues**: Apply consistent formatting and naming conventions
- **Single-use variables**: Inline variables used only once in changed code blocks to improve readability
- **Long functions**: If a changed function exceeds 15 lines, consider breaking it into smaller functions when it makes the code easier to understand and follow
- **Unnecessary operations**: Remove redundant method calls and operations when they don't affect the business logic

### Safety Considerations

- Always ask for confirmation before executing potentially dangerous operations
- Create backups for non-git files before modification
- Validate user input and API responses
- Handle network errors and timeouts gracefully
- Use appropriate exit codes for different error conditions
- When fixing PR warnings, always ensure the changes are minimal and focused on the specific issue identified
- Test fixes thoroughly to ensure they don't introduce new problems