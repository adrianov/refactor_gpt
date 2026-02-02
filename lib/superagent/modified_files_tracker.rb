# frozen_string_literal: true

require 'shellwords'

# Collects modified/untracked code files from the repo (git) for session context.
# Used to pass a bounded list of modified code files to the LLM; storage/cap in SessionTracker.
module ModifiedFilesTracker
  MAX_ENTRIES = 100

  CODE_EXTENSIONS = %w[
    .rb .c .h .cpp .hpp .cc .cxx .java .py .js .ts .jsx .tsx .go .rs .swift
    .kt .scala .cs .php .pl .pm .sh .bash .zsh .lua .r .m .mm .sql .graphql
    .vue .svelte .css .scss .sass .less .html .htm .xml .json .yaml .yml
    .toml .ini .conf .md .markdown .txt .rake .gemspec
  ].freeze

  module_function

  # Returns paths of modified/untracked code files (not .gitignored), relative to root. Empty if not a git repo.
  def collect_from_repo(root)
    return [] unless File.directory?(File.join(root, '.git'))

    modified = `git -C #{Shellwords.escape(root)} diff --name-only HEAD 2>#{File::NULL}`.strip.lines.map(&:strip)
    untracked = `git -C #{Shellwords.escape(root)} ls-files --others --exclude-standard 2>#{File::NULL}`.strip.lines.map(&:strip)
    (modified + untracked).uniq.select { |path| code_file?(path) }
  end

  def code_file?(path)
    ext = File.extname(path).downcase
    CODE_EXTENSIONS.include?(ext)
  end
end
