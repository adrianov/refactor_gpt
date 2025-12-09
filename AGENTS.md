# RefactorGPT Tools

A collection of Ruby scripts that leverage GPT-5.1 to help with code refactoring, searching, and bash command generation.

## Project Overview

RefactorGPT Tools provides command-line utilities for:
- **Code refactoring** (`refactor_gpt.rb`) - Automated code improvement while preserving functionality
- **Code searching** (`ag_gpt.rb`) - Natural language interface for searching codebases using The Silver Searcher
- **Bash command generation** (`bash_gpt.rb`) - Generate and execute bash commands from natural language
- **General assistance** (`ask_gpt.rb`) - Terminal-based AI assistant for questions and explanations
- **Git commit planning** (`git_commit_gpt.rb`) - Create structured git commits based on changes

## Ruby Development Guidelines

When working with this codebase, follow these refactoring principles:

### Core Principles
- **Correctness**: Fix bugs, improve error handling, validate inputs
- **Readability**: Use clear names, follow Ruby conventions, meaningful methods
- **Simplicity**: Keep methods under 15 lines when possible, remove dead code
- **Consistency**: Follow idiomatic Ruby style and existing patterns
- **Behavior Preservation**: Don't change functionality unless fixing bugs or explicitly requested

### File Conventions
- Script files follow the pattern `*_gpt.rb`
- Use shebang `#!/usr/bin/env ruby` at the top
- Keep dependencies minimal
- Follow existing error handling patterns
- Prefer HEREDOC for multiline strings over string concatenation

### Comments
- Preserve existing comments unless they refer to changed code
- Don't add new comments unless explicitly requested
- Use comments only for complex business logic

### Safety
- Always ask for confirmation before dangerous operations
- Create backups for non-git files
- Handle network errors gracefully
- Use appropriate exit codes