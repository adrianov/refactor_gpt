# RefactorGPT Tools

A collection of Ruby scripts that leverage GPT-5.1 to help with code refactoring, searching, and bash command generation.

## Prerequisites

- Ruby 2.7 or higher
- The Silver Searcher (`ag`) for code searching functionality
- OpenAI API access
- Optional: [`glow`](https://github.com/charmbracelet/glow) for formatted Markdown output in `ask_gpt.rb`

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
4. (Optional) Install `glow` for nicer formatted output in `ask_gpt.rb`:
   - macOS: `brew install glow`
   - Ubuntu (via snap): `sudo snap install glow`
   - Other systems: See [glow installation guide](https://github.com/charmbracelet/glow#installation)

## Configuration

1. Copy `.env.example` to `.env`:
   ```bash
   cp .env.example .env
   ```

2. Edit `.env` and set your API credentials. Set `MODEL` (and optionally `TECHNICAL_MODEL`, `IMAGE_MODEL`). Backend is chosen from the model name (e.g. `claude-*` → Claude, `gemini-*` → Gemini, `gpt-*` → OpenAI). Configure the backend(s) you use:

   **Unified model names:**
   ```
   MODEL=claude-sonnet-4-6
   TECHNICAL_MODEL=claude-haiku-4-5
   IMAGE_MODEL=gemini-2.0-flash-exp
   ```

   **Claude** (for `claude-*` models): `CLAUDE_BASE_URL`, `CLAUDE_ACCESS_TOKEN`

   **OpenAI** (for `gpt-*`, `composer-*`, `dall-e*`): `OPENAI_BASE_URL`, `OPENAI_ACCESS_TOKEN`

   **Gemini** (for `gemini-*`): `GEMINI_BASE_URL`, `GEMINI_ACCESS_TOKEN`

   **OpenRouter fallback** (optional, used automatically after retryable `429`, `5xx`, or network failures): `OPENROUTER_API_KEY`
   Optional overrides: `OPENROUTER_BASE_URL`, `OPENROUTER_MODEL`

   Default model is inferred from which token is set (Claude preferred, then Gemini, then OpenAI). The `--search` flag uses OpenAI's search model.

   **Proxy Configuration (Optional):**
   - Set `PROXY_URL` and/or standard `ALL_PROXY` / `HTTPS_PROXY` / `HTTP_PROXY`
   - SOCKS5 is preferred when several proxy vars are set (`socks://` is normalized to `socks5://`)
   - Example: `PROXY_URL=socks5://127.0.0.1:1080`
   - Omit or leave empty if no proxy is needed

## Setting up Aliases

To make the scripts easier to use from anywhere, you can add aliases to your `.zshrc` file.

1. Navigate to the project directory in your terminal:
   ```bash
   cd /path/to/refactor_gpt
   ```
   *(Replace `/path/to/refactor_gpt` with the actual path)*

2. Run the following commands to add the aliases to your `.zshrc`:
   ```bash
    echo "alias refactor='$(pwd)/refactor_gpt.rb'" >> ~/.zshrc
    echo "alias agpt='$(pwd)/ag_gpt.rb'" >> ~/.zshrc
    echo "alias bashgpt='$(pwd)/bash_gpt.rb'" >> ~/.zshrc
    echo "alias ask='$(pwd)/ask_gpt.rb'" >> ~/.zshrc
    echo "alias gcommit='$(pwd)/git_commit_gpt.rb'" >> ~/.zshrc
    echo "alias ge='$(pwd)/git_explain_gpt.rb'" >> ~/.zshrc
    echo "alias superagent='$(pwd)/superagent.rb'" >> ~/.zshrc
   ```

3. Activate the aliases by either:
   - Restarting your terminal, or
   - Running `source ~/.zshrc`

## Terminal Title Updates

`superagent.rb` automatically updates the terminal tab title to show status indicators:
- "✅ Done" when the task completes successfully
- "❌ Error" when all attempts fail

The title is updated before the program prompts you to press Enter to continue, allowing you to see the status at a glance.

Now you can use the commands directly from any directory:
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

An automated code agent that executes commands across multiple AI models sequentially, automatically verifying results and retrying with fix instructions when verification fails.

Usage:
```bash
./superagent.rb "Your request here"
```

Features:
- **Multi-model fallback**: Sequentially tries Gemini, Claude, and other models.
- **Automatic verification**: Uses a separate agent pass to verify that changes solve the request.
- **Out-of-scope handling**: If the request is out of project scope, the agent may output `FAILED: OUT_OF_SCOPE`; verification is skipped and the run is treated as failed.
- **Reuse agent process** (`--stdin-commands`): Read JSON job lines from stdin, run one agent step per job (implement/verification/refactor/ask), write `{"done":true,"code":N}` to stdout. Lets a driver keep one long-lived Ruby process and send multiple jobs.
- **Reuses agent process**: After each run the agent prompts for the next request (same directory). Type `/quit` to exit. Lock is held until exit so only one instance per project.
- **Self-correction**: Automatically retries with specific fix instructions if verification fails.
- **Queue requests during run**: Visible queue UI (hint at start, "Queue (N): type request, Enter twice to add" before each attempt); extra requests are sent together to the next run.
- **Detailed logging**: Provides timestamped logs and tracks git status throughout the process.
- **Performance tracking**: Reports total runtime upon completion.
- **Interactive mode**: Supports interactive request input if no arguments are provided.

### refactor_gpt.rb

A tool for automated code refactoring using GPT-5.1. It analyzes your code and suggests improvements while maintaining existing functionality.

Usage:
./refactor_gpt.rb <file_to_refactor.rb> ["Optional specific refactoring instructions"]

Features:
- Preserves existing comments and business logic
- Ensures functions are under 15 lines
- Improves variable naming
- Simplifies complex logic
- Handles error cases
- Creates backups for non-git files
- Shows diff of changes

### ag_gpt.rb

A natural language interface for searching through your codebase using The Silver Searcher (`ag`).

Usage:
./ag_gpt.rb "What to search for in natural language"

Features:
- Converts natural language queries into optimized `ag` search commands
- Automatically detects project keywords
- Excludes minified files
- Supports various code file extensions
- Shows search results directly in terminal

### bash_gpt.rb

Generates and executes bash commands based on natural language descriptions using the `gpt-5-nano` model.

Usage:
./bash_gpt.rb "What you want to do"

Features:
- Generates appropriate bash commands based on your request
- Includes system information in command generation
- Automatically executes safe commands (grep, ls, df, etc.)
- Asks for confirmation before executing potentially dangerous commands
- Supports common Unix commands and utilities

### ask_gpt.rb

A general-purpose AI assistant for asking questions, getting explanations, or brainstorming ideas from the terminal.

Usage:
./ask_gpt.rb "Your question or request here"
./ask_gpt.rb --search "Your question requiring web search"

Features:
- Answers programming and non-programming questions
- Can explain code snippets or concepts
- Works as a quick terminal-based AI assistant
- Markdown rendering with syntax highlighting:
  - **md2term** (preferred) - Install with `pip install md2term` or `uv tool install md2term`
  - **glow** (fallback) - Install with `brew install glow` or equivalent for your system
  - Falls back to plain text if neither is available
- Auto-detects AI provider from `.env` configuration:
  - **Gemini 3 Flash** (preferred, if `GEMINI_ACCESS_TOKEN` is configured)
  - **GPT models** via OpenAI API (if `OPENAI_ACCESS_TOKEN` is configured)
  - **Search mode** (`--search` flag) always uses OpenAI's `gpt-4o-search-preview` model
  - **OpenRouter fallback** for retryable primary API failures when `OPENROUTER_API_KEY` is configured

### git_commit_gpt.rb

An assistant for planning and creating structured git commits based on your current working tree.

Usage:
./git_commit_gpt.rb [--watch] [--debug] [--auto [0-100]] [--push] [hint...]

Features:
- `--watch`: monitor analyzed files for changes and re-run planning every 30s when changes are detected
- `--auto [level]`: commit without prompting when every warning is ≤ `level`% (default 50; also `--auto=75`). For scripts/background use: prints warnings and the commit/push outcome only — skips diff, RuboCop hint, progress bar, impact, and sounds. Without `--push`, skips push without asking.
- `--push`: push after a successful commit without asking
- Reads `git status --porcelain` and `git diff` for the current repository
- Groups changed files into a small number of coherent commits (by feature, refactor, docs, tests, etc.)
- Generates conventional-style one-line commit messages
- Ensures every changed file is included in exactly one suggested commit
- Prints a clear commit plan and asks for confirmation before running any `git add`/`git commit` commands
- Reviews diffs for potential issues and prints warnings with a probability score
- Falls back to OpenRouter automatically when the primary API is rate-limited or temporarily unavailable

### git_explain_gpt.rb

An assistant that analyzes git changes and creates comprehensive technical explanations in Markdown format.

Usage:
./git_explain_gpt.rb [--debug]

Features:
- Analyzes `git status`, `git diff`, recent commits, and terminal history
- Creates detailed technical explanations with code analysis and integration impact
- Includes specific file paths and line numbers for all changes
- Uses `glow` for formatted Markdown output when available
- Provides testing recommendations and developer notes for the changes

## Safety Features

- All scripts require explicit confirmation for potentially dangerous operations
- Non-git files are backed up before modification
- Safe command list for automatic execution
- Environment variable validation
- Error handling for API responses

## Contributing

Feel free to submit issues and enhancement requests!
