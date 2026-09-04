# RefactorGPT Tools

Ruby CLI tools that use large language models for refactoring, code search, shell commands, and git workflows.

## Prerequisites

- Ruby 2.7 or higher
- The Silver Searcher (`ag`) for code search
- OpenRouter API key
- Optional: [`glow`](https://github.com/charmbracelet/glow) for Markdown output in `ask_gpt.rb`

## Installation

1. Clone this repository
2. Install required Ruby gems (either):
   ```bash
   bundle install
   ```
   or:
   ```bash
   gem install ruby_llm typhoeus faraday-typhoeus oj parser ruby-progressbar colorize zeitwerk
   ```
3. Install The Silver Searcher (required for `ag_gpt.rb`):
   - macOS: `brew install the_silver_searcher`
   - Ubuntu/Debian: `apt-get install silversearcher-ag`
   - Other systems: See [The Silver Searcher installation guide](https://github.com/ggreer/the_silver_searcher#installation)
4. (Optional) Install `glow` for Markdown rendering in `ask_gpt.rb`:
   - macOS: `brew install glow`
   - Ubuntu (via snap): `sudo snap install glow`
   - Other systems: See [glow installation guide](https://github.com/charmbracelet/glow#installation)

## Configuration

1. Copy `.env.example` to `.env`:
   ```bash
   cp .env.example .env
   ```

2. Edit `.env` and set `OPENROUTER_API_KEY` (required). All tools call OpenRouter with the model
   `stealth/ox-alpha` by default.

   Optional overrides:
   - `OPENROUTER_BASE_URL` (default `https://openrouter.ai/api/v1`)
   - `MODEL` (default `stealth/ox-alpha`)
   - `REQUEST_TIMEOUT` (default `600` seconds)

   A stable system prompt (instructions and project rules) is cached on OpenRouter via `cache_control`.
   Working-tree state such as git status, diffs, and directory listings goes in the user message so
   different changes still hit the same cache.

   **Proxy (optional):**
   - Add `PROXY_URL` to this app's `.env` (example: `PROXY_URL=socks5://127.0.0.1:1080`)
   - `socks://` and `socks5h://` become `socks5://`
   - Shell `HTTP_PROXY` / `HTTPS_PROXY` are unused; they never replace `.env`
   - Leave `PROXY_URL` unset when no proxy is needed

## Setting up Aliases

To run the scripts from any directory, add aliases to `~/.zshrc`.

1. Go to the project directory:
   ```bash
   cd /path/to/refactor_gpt
   ```
   *(Replace `/path/to/refactor_gpt` with the actual path)*

2. Append the aliases:
   ```bash
    echo "alias refactor='$(pwd)/refactor_gpt.rb'" >> ~/.zshrc
    echo "alias agpt='$(pwd)/ag_gpt.rb'" >> ~/.zshrc
    echo "alias bashgpt='$(pwd)/bash_gpt.rb'" >> ~/.zshrc
    echo "alias ask='$(pwd)/ask_gpt.rb'" >> ~/.zshrc
    echo "alias gcommit='$(pwd)/git_commit_gpt.rb'" >> ~/.zshrc
    echo "alias ge='$(pwd)/git_explain_gpt.rb'" >> ~/.zshrc
   ```

3. Reload the shell:
   - Restart the terminal, or
   - Run `source ~/.zshrc`

Examples from any directory:
refactor file.rb "make it more readable"
agpt "find all database queries"
bashgpt "list all files modified today"
ask "explain how Ruby blocks work"
ask --short "quick answer, please"
gcommit "plan and create structured git commits"
ge "explain current git changes"

## Available Scripts

### refactor_gpt.rb

Automated refactoring that improves code while keeping behavior the same.

Usage:
./refactor_gpt.rb <file_to_refactor.rb> ["Optional specific refactoring instructions"]

Features:
- Preserves existing comments and business logic
- Keeps functions under 15 lines
- Improves variable naming
- Simplifies complex logic
- Handles error cases
- Creates backups for non-git files
- Shows a diff of the changes

### ag_gpt.rb

Turns a plain-language query into an `ag` (The Silver Searcher) command.

Usage:
./ag_gpt.rb "What to search for in natural language"

Features:
- Builds an `ag` command from the query
- Detects project keywords
- Skips minified files
- Covers common code file extensions
- Prints matches in the terminal

### bash_gpt.rb

Writes and runs a bash command from a plain-language request.

Usage:
./bash_gpt.rb "What you want to do"

Features:
- Includes host details when choosing a command
- Runs safe commands (grep, ls, df, etc.) without asking
- Asks before running anything that could be destructive
- Covers common Unix commands and utilities

### ask_gpt.rb

A terminal assistant for questions, explanations, and quick ideas.

Usage:
./ask_gpt.rb "Your question or request here"
./ask_gpt.rb --short "Your question, answered briefly"

Features:
- Answers programming and non-programming questions
- Can explain code snippets or concepts
- Meant for short questions from the terminal
- Markdown rendering with syntax highlighting:
  - **md2term** (preferred) - Install with `pip install md2term` or `uv tool install md2term`
  - **glow** (fallback) - Install with `brew install glow` or equivalent for your system
  - Plain text if neither is installed

### git_commit_gpt.rb

Plans and creates structured git commits from the current working tree.

Usage:
./git_commit_gpt.rb [--watch] [--debug] [--auto [0-100]] [--commit auto|yes|no] [--push] [--file PATH]... [-- PATH...] [hint...]

Features:
- `--file PATH`: repeatable. Restrict planning and the commit to this pathspec. Existing files or directories, deleted files git still lists, paths that contain `/`, and arguments after `--` count as well. A matching rename (both names) and deletions in the same directory or the parent directory are included; other dirty files stay unstaged.
- `--watch`: re-plan every 30s when analyzed files change
- `--commit auto|yes|no`: default `auto` (flag may be omitted). `auto` — commit if there are no warnings, else ask. `yes` — commit. `no` — skip commit and push.
- `--auto [level]`: quiet mode; commits when every warning is ≤ `level`% (default 50; also `--auto=75`). Prints warnings and the commit/push result only — omits diff, RuboCop hint, progress bar, impact, and sounds. Without `--push`, does not ask to push. `--commit yes|no` overrides whether to commit.
- `--push`: after a successful commit, push without asking. Ignored if nothing was committed.
- Reads `git status --porcelain` and `git diff` for the current repository
- Groups changed files into a small number of coherent commits (by feature, refactor, docs, tests, etc.)
- Writes conventional-style one-line commit messages
- Puts every changed file in exactly one suggested commit
- Drops planned paths that are not in `git status`; `git commit` only receives staged pathspecs
- Prints a commit plan before any `git add`/`git commit`
- Reviews the diff for defects and for breaks of Cursor rules from the project `.cursor/rules/` and the user `~/.cursor/rules/`, then prints each warning with a probability score

### git_explain_gpt.rb

Reads the current git changes and writes a technical explanation in Markdown.

Usage:
./git_explain_gpt.rb [--debug] [--file PATH]... [-- PATH...] [path...]

Features:
- `--file PATH` (repeatable), `-- PATH...`, an existing file or directory, or a deleted file git still lists: explain only those pathspecs, and only source-code extensions. A matching rename (both names) and deletions in the same directory or the parent directory are included; other dirty files are left out.
- Uses `git status`, `git diff`, recent commits, and terminal history
- Explains the change, the code, and how it fits the rest of the project
- Cites file paths and line numbers
- Renders with `glow` when it is installed
- Adds testing notes and developer remarks

### hooks/quality.rb

Cursor `stop` hook: after each completed agent turn, runs an abcop lint gate (plus a static RSpec no-def scan when `.cursor/rules/rspec-no-def.mdc` exists), a short review, optional new-`.md` wording, then `git_commit_gpt --auto`. One follow-up message per stop; stages retry until clean. Quality runs only when this is the last open Cursor/omp session on the project (sibling logs must end with `turn_ended` / `session_exit`, or exceed the open-session TTL; no presence lock files). Cursor Ask mode (`/ask`) is skipped: `sessionStart` records `composer_mode` and later stops exit immediately. Cursor sessions also skip unless a Write/StrReplace/Delete/EditNotebook in this session targeted the repo (leftover git dirt is not enough); omp still uses git. Change detection is git-based (uncommitted work vs HEAD plus untracked files). Scatter/verify re-emit is skipped when the edited-module count is unchanged. Logic lives in `hooks/quality/` (`config`, `support`, `composer_mode`, `state_store`, `repo_gates`, `transcripts`, `git_changes`, `formal`, `rspec_def`, `review`, `stages`, `commit`).

Install as a user hook (from `~/.cursor/`):

```json
{
  "version": 1,
  "hooks": {
    "sessionStart": [
      {
        "command": "/absolute/path/to/refactor_gpt/hooks/quality.rb"
      }
    ],
    "stop": [
      {
        "command": "/absolute/path/to/refactor_gpt/hooks/quality.rb",
        "timeout": 600,
        "loop_limit": 6
      }
    ]
  }
}
```

Or copy/symlink into `~/.cursor/hooks/` and point `hooks.json` at `./hooks/quality.rb`. When the hook does not live next to `git_commit_gpt.rb`, set `GIT_COMMIT_GPT` to that script. Optional `QUALITY_OWN_GITHUB=your-github-user` enables `--push` on matching `github.com` remotes.

## Safety Features

- Destructive actions ask for confirmation first
- Non-git files are backed up before they are changed
- A safe-command list for automatic execution
- Environment variable checks
- API error handling

## Contributing

Issues and pull requests are welcome.
