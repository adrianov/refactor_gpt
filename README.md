# RefactorGPT Tools

A collection of Ruby scripts that leverage GPT-5.1 to help with code refactoring, searching, and bash command generation.

## Prerequisites

- Ruby 2.7 or higher
- The Silver Searcher (`ag`) for code searching functionality
- OpenAI API access
- Optional: [`glow`](https://github.com/charmbracelet/glow) for formatted Markdown output in `ask_gpt.rb`

## Installation

1. Clone this repository
2. Install required Ruby gems:
   ```bash
   gem install httpx oj ruby-progressbar colorize
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

2. Edit `.env` and set your API credentials:

   **For OpenAI (GPT models):**
   ```
   OPENAI_BASE_URL=https://api.openai.com/v1
   OPENAI_ACCESS_TOKEN=your-api-key-here
   ```

   **For Gemini 3 Flash (preferred when available):**
   ```
   GEMINI_BASE_URL=https://opencode.ai/zen/v1
   GEMINI_ACCESS_TOKEN=your-api-key-here
   GEMINI_MODEL=gemini-3-flash
   ```

   **Provider Selection:**
   - If `GEMINI_ACCESS_TOKEN` is configured, Gemini will be used by default
   - If only `OPENAI_ACCESS_TOKEN` is configured, OpenAI will be used
   - The `--search` flag always uses OpenAI's search model

   **Proxy Configuration (Optional):**
   - Set `PROXY_URL` if you need to use a proxy to access the API
   - Supported protocols: `http`, `https`, `socks5`
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
- **Self-correction**: Automatically retries with specific fix instructions if verification fails.
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

### git_commit_gpt.rb

An assistant for planning and creating structured git commits based on your current working tree.

Usage:
./git_commit_gpt.rb

Features:
- Reads `git status --porcelain` and `git diff` for the current repository
- Groups changed files into a small number of coherent commits (by feature, refactor, docs, tests, etc.)
- Generates conventional-style one-line commit messages
- Ensures every changed file is included in exactly one suggested commit
- Prints a clear commit plan and asks for confirmation before running any `git add`/`git commit` commands
- Reviews diffs for potential issues and prints warnings with a probability score

### git_explain_gpt.rb

An assistant that analyzes git changes and creates comprehensive technical explanations in Markdown format.

Usage:
./git_explain_gpt.rb [--debug]

Features:
- Analyzes `git status`, `git diff`, recent commits, and terminal history
- Creates detailed technical explanations with code analysis and integration impact
- Includes specific file paths and line numbers for all changes
- Uses `glow` for formatted Markdown output when available
- Incorporates AGENTS.md development guidelines when present
- Provides testing recommendations and developer notes for the changes

## Safety Features

- All scripts require explicit confirmation for potentially dangerous operations
- Non-git files are backed up before modification
- Safe command list for automatic execution
- Environment variable validation
- Error handling for API responses

## Contributing

Feel free to submit issues and enhancement requests!
