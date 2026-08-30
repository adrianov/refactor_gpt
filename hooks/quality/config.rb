# frozen_string_literal: true

::Kernel.require('set')

module Quality
  HOOKS = File.expand_path('..', __dir__)
  STATE = File.join(HOOKS, 'state')
  # Content digests of reviewed markdown files that live outside any git repo
  # (Obsidian vaults): no HEAD to diff against, so fire once per content state.
  MD_REVIEW_DIGESTS = File.join(STATE, 'md-review-digests.json')
  # XDG console-app convention (same layout on macOS and Linux): all hook
  # logs live under $XDG_DATA_HOME (fallback ~/.local/share)/quality-hook.
  DATA_HOME = begin
    xdg = ENV['XDG_DATA_HOME'].to_s.chomp('/')
    base = xdg.empty? ? File.join(ENV['HOME'].to_s, '.local/share') : xdg
    File.join(base, 'quality-hook')
  end
  LOGS = File.join(DATA_HOME, 'logs')
  COMMIT_GPT = begin
    from_env = ENV['GIT_COMMIT_GPT'].to_s
    from_env.empty? ? File.expand_path('../../git_commit_gpt.rb', __dir__) : from_env
  end
  RBENV_RUBY = begin
    home = ENV['HOME'].to_s
    [
      File.join(home, '.rbenv/shims/ruby'),
      '/opt/homebrew/opt/ruby/bin/ruby',
      '/usr/local/opt/ruby/bin/ruby',
      '/usr/bin/ruby'
    ].find { |p| File.executable?(p) } || 'ruby'
  end
  OWN_GITHUB = ENV['QUALITY_OWN_GITHUB'].to_s.strip
  SCATTER = 6
  LOCK_AGE = 600
  # Session logs older than this are ignored (idle/abandoned — not “still running”).
  SESSION_RECENT_AGE = 300
  LIMIT = 6000
  # Safety ceiling only: normal VERIFY diffs are attached in full.
  VERIFY_DIFF_LIMIT = 1_000_000
  FOLLOWUP_REPEATS = 2
  VERIFY = 'Check if the issues are resolved fully and properly. Fix without bloat if needed.'
  SCHEMA_MSG = 'db/schema.rb was edited. Make schema.rb changes minimal, covering only current task scope.'
  MD_MSG = 'Improve phrasing and synonym choice in these new .md files.'
  ABCOP_LEFT = 'abcop found issues in code changed this turn: methods above the ABC-size ' \
               'threshold and variables assigned once or never used. Simplify complex methods ' \
               '(extract helpers only when it clearly reduces complexity), inline single-use ' \
               'variables, and remove dead assignments.'
  # Our own emitted messages re-enter through Cursor as the next user turn;
  # chain detection matches on them so follow-ups keep their stage position.
  FOLLOWUP_RE = /
    Check\ if\ the\ issues\ are\ resolved\ fully\ and\ properly
    |Improve\ phrasing\ and\ synonym\ choice
    |db\/schema\.rb\ was\ edited
    |modules\ were\ edited\ during\ this\ feature\ implementation
    |abcop\ found\ issues\ in\ code\ changed
    |Auto-commit\ skipped:
    |Warning\ in\
  /x
  MAIN_EXT = /
    \.(rs|rb|py|ts|tsx|js|jsx|mjs|cjs|go|swift|java|kt|kts|c|cc|cpp|cxx|
    h|hpp|cs|php|scala|clj|ex|exs|hs|ml|mli|vue|svelte|
    css|scss|sass|less|sql|sh|bash|zsh)$
  /ix
  SPEC_RE = %r{(^|/)(spec|specs|test|tests|__tests__|__mocks__|testdata|testing|fixtures)(/|$)}i
  SPEC_FILE_RE = %r{(^|/)(conftest\.py|test\.[^./]+|spec\.[^./]+)$}i
  SPEC_SUFFIX_RE = %r{([._-](spec|test|tests)|_(spec|test|tests))\.[^./]+$}i
  TEST_PREFIX_RE = %r{(^|/)test_[^/]+\.[^./]+$}i
end
