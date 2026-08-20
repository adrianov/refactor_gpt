# RefactorGPT Tools

Ruby CLI tools that use large language models for refactoring, code search, shell commands, and git workflows.

## Prerequisites

- Ruby 2.7 or higher
- The Silver Searcher (`ag`) for code search
- OpenAI API access
- Optional: [`glow`](https://github.com/charmbracelet/glow) for Markdown output in `ask_gpt.rb`

## Installation

1. Clone this repository
2. Install required Ruby gems (either):
   ```bash
   bundle install
   ```
   or:
   ```bash
   gem install httpx oj ruby-progressbar colorize tty-box tty-cursor
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

2. Edit `.env` and set your API credentials. Set `MODEL` (and optionally `TECHNICAL_MODEL`, `IMAGE_MODEL`). The backend follows the model name (e.g. `claude-*` → Claude, `gemini-*` → Gemini, `gpt-*` → OpenAI). Configure the backend(s) you use:

   **Example models:**
   ```
   MODEL=claude-sonnet-4-6
   TECHNICAL_MODEL=claude-haiku-4-5
   IMAGE_MODEL=gemini-2.0-flash-exp
   ```

   **Claude** (for `claude-*` models): `CLAUDE_BASE_URL`, `CLAUDE_ACCESS_TOKEN`

   **OpenAI** (for `gpt-*`, `composer-*`, `dall-e*`): `OPENAI_BASE_URL`, `OPENAI_ACCESS_TOKEN`

   **Gemini** (for `gemini-*`): `GEMINI_BASE_URL`, `GEMINI_ACCESS_TOKEN`

   **OpenRouter fallback** (optional; used after retryable `429`, `5xx`, or network failures): `OPENROUTER_API_KEY`
   Optional overrides: `OPENROUTER_BASE_URL`, `OPENROUTER_MODEL`

   If `MODEL` is unset, the default follows which token is present (Claude first, then Gemini, then OpenAI). The `--search` flag uses OpenAI's search model.

   Supported providers (Anthropic, Qwen, Gemini, and Auto) cache a stable system prompt (instructions and project rules) on OpenRouter via `cache_control`. Working-tree state such as git status, diffs, and directory listings goes in the user message so different changes still hit the same cache.

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
    echo "alias superagent='$(pwd)/superagent.rb'" >> ~/.zshrc
   ```

3. Reload the shell:
   - Restart the terminal, or
   - Run `source ~/.zshrc`

## Terminal Title Updates

`superagent.rb` updates the terminal tab title:
- "✅ Done" after a successful run
- "❌ Error" after every attempt fails

The title is set before the program waits for Enter, so you can see the outcome at a glance.

Examples from any directory:
refactor file.rb "make it more readable"
agpt "find all database queries"
bashgpt "list all files modified today"
ask "explain how Ruby blocks work"
ask --search "search the web for this"
gcommit "plan and create structured git commits"
ge "explain current git changes"
superagent "refactor the whole project to use dry-rb"

## Available Scripts

### superagent.rb

A TUI agent that tries models in sequence, checks that the result matches the request, and retries with fix instructions when it does not.

Usage:
```bash
./superagent.rb "Your request here"
```

Features:
- **Multi-model fallback**: Tries Gemini, Claude, and other models in order.
- **Automatic verification**: A separate agent pass checks that the changes satisfy the request.
- **Out-of-scope handling**: If the request is outside the project, the agent may output `FAILED: OUT_OF_SCOPE`; verification is skipped and the run is treated as failed.
- **Stdin job driver** (`--stdin-commands`): Read JSON job lines from stdin, run one agent step per job (implement/verification/refactor/ask), write `{"done":true,"code":N}` to stdout. A driver can keep one long-lived Ruby process and send several jobs.
- **Session reuse**: After each run the agent asks for the next request (same directory). Type `/quit` to exit. The lock is held until exit so only one instance runs per project.
- **Self-correction**: Retries with specific fix instructions if verification fails.
- **Queue during a run**: Visible queue UI (hint at start, "Queue (N): type request, Enter twice to add" before each attempt); extra requests are sent together on the next run.
- **Detailed logging**: Timestamped logs and git status throughout the run.
- **Runtime**: Prints total elapsed time when finished.
- **Interactive mode**: Prompts for a request when none is given on the command line.

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
./ask_gpt.rb --search "Your question requiring web search"

Features:
- Answers programming and non-programming questions
- Can explain code snippets or concepts
- Meant for short questions from the terminal
- Markdown rendering with syntax highlighting:
  - **md2term** (preferred) - Install with `pip install md2term` or `uv tool install md2term`
  - **glow** (fallback) - Install with `brew install glow` or equivalent for your system
  - Plain text if neither is installed
- Picks a provider from `.env`:
  - **Gemini 3 Flash** if `GEMINI_ACCESS_TOKEN` is set
  - **GPT models** via the OpenAI API if `OPENAI_ACCESS_TOKEN` is set
  - **Search mode** (`--search`) always uses OpenAI's `gpt-4o-search-preview` model
  - **OpenRouter fallback** after retryable primary API failures when `OPENROUTER_API_KEY` is set

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
- Falls back to OpenRouter when the primary API is rate-limited or briefly unavailable

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

## Safety Features

- Destructive actions ask for confirmation first
- Non-git files are backed up before they are changed
- A safe-command list for automatic execution
- Environment variable checks
- API error handling

## Contributing

Issues and pull requests are welcome.
