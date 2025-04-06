# RefactorGPT Tools

A collection of Ruby scripts that leverage GPT-4 to help with code refactoring, searching, and bash command generation.

## Prerequisites

- Ruby 2.7 or higher
- The Silver Searcher (`ag`) for code searching functionality
- OpenAI API access

## Installation

1. Clone this repository
2. Install required Ruby gems:
   ```bash
   gem install excon oj ruby-progressbar
   ```
3. Install The Silver Searcher (required for `ag_gpt.rb`):
   - macOS: `brew install the_silver_searcher`
   - Ubuntu/Debian: `apt-get install silversearcher-ag`
   - Other systems: See [The Silver Searcher installation guide](https://github.com/ggreer/the_silver_searcher#installation)

## Configuration

1. Copy `.env.example` to `.env`:
   ```bash
   cp .env.example .env
   ```

2. Edit `.env` and set your OpenAI API credentials:
   ```
   OPENAI_BASE_URL=https://api.openai.com/v1
   OPENAI_ACCESS_TOKEN=your-api-key-here
   ```

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
   ```

3. Activate the aliases by either:
   - Restarting your terminal, or
   - Running `source ~/.zshrc`

Now you can use the commands directly from any directory:
```bash
refactor file.rb "make it more readable"
agpt "find all database queries"
bashgpt "list all files modified today"
```

## Available Scripts

### refactor_gpt.rb

A tool for automated code refactoring using GPT-4. It analyzes your code and suggests improvements while maintaining existing functionality.

Usage:
```bash
./refactor_gpt.rb <file_to_refactor.rb> ["Optional specific refactoring instructions"]
```

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
```bash
./ag_gpt.rb "What to search for in natural language"
```

Features:
- Converts natural language queries into optimized `ag` search commands
- Automatically detects project keywords
- Excludes minified files
- Supports various code file extensions
- Shows search results directly in terminal

### bash_gpt.rb

Generates and executes bash commands based on natural language descriptions.

Usage:
```bash
./bash_gpt.rb "What you want to do"
```

Features:
- Generates appropriate bash commands based on your request
- Includes system information in command generation
- Automatically executes safe commands (grep, ls, df, etc.)
- Asks for confirmation before executing potentially dangerous commands
- Supports common Unix commands and utilities

## Safety Features

- All scripts require explicit confirmation for potentially dangerous operations
- Non-git files are backed up before modification
- Safe command list for automatic execution
- Environment variable validation
- Error handling for API responses

## Contributing

Feel free to submit issues and enhancement requests! 