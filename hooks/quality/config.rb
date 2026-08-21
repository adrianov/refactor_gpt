# frozen_string_literal: true

::Kernel.require('set')

module Quality
  HOOKS = File.expand_path('..', __dir__)
  STATE = File.join(HOOKS, 'state')
  LOGS = File.join(HOOKS, 'logs')
  COMMIT_GPT = begin
    from_env = ENV['GIT_COMMIT_GPT'].to_s
    from_env.empty? ? File.expand_path('../../git_commit_gpt.rb', __dir__) : from_env
  end
  RBENV_RUBY = File.join(ENV['HOME'].to_s, '.rbenv/shims/ruby')
  OWN_GITHUB = ENV['QUALITY_OWN_GITHUB'].to_s.strip
  MAX_LINES = 200
  SCATTER = 6
  LOCK_AGE = 600
  ACTIVE_LOCK_AGE = 7200
  LIMIT = 6000
  VERIFY = 'Check if the issue is resolved fully and properly. Fix without bloat if needed.'
  SCHEMA_MSG = 'db/schema.rb was edited. Make schema.rb changes minimal, covering only current task scope.'
  MD_MSG = 'Improve phrasing and synonym choice in these new .md files.'
  RUBOCOP_LEFT = 'RuboCop auto-correct left remaining offenses. Fix all of them in this pass without bloat.'
  ABC_LEFT = 'RuboCop Metrics/AbcSize found methods that are too complex. Simplify them without bloat; ' \
             'extract helpers only when it clearly reduces complexity.'
  LIZARD_LEFT = 'lizard found functions above the cyclomatic complexity threshold (CCN > 15). ' \
                'Simplify them without bloat; extract helpers only when it clearly reduces complexity.'
  OWN_SPEC = <<~MSG.chomp
    Shrink that file only this turn by removing real weight, not by packing the text:
    1. Drop redundant examples and duplicated setup first.
    2. If still ≥ 200 lines, extract ≥ 100 lines as a sibling spec named for the concern (not *Part2*) — one coherent slice (a path, rule, or collaborator). Shared lets go to support or a shared context.
    3. Seat it in a readable spec tree next to the code under test (git mv). Do not park another peer in a flat catch-all when a nested folder fits.
    4. Keep coverage and normal readable formatting. Deleting blank lines or rewriting into denser one-liners does not count. Pre-existing size is not an excuse to skip.
    Skip only if splitting would make the specs worse — say what you tried. "Needs a bigger refactor" is not a skip.
  MSG
  OTHER_SPEC = <<~MSG.chomp
    Review each one for redundancy: examples covering a path that is already tested, setup copied from example to example instead of a shared let or before, unused lets, stubs and includes, fixtures the code under test never reads. Remove only what goes away without losing a check - keep the edge cases. Do not "fix" length by stripping blank lines or packing statements into harder-to-read one-liners. Run these files after editing. If there is nothing to cut, say so and leave the file alone.
  MSG
  MODULE_SHRINK = <<~MSG.chomp
    Shrink that file only this turn by removing real weight, not by packing the text:
    1. Drop dead %<drop>s and duplication first.
    2. If still ≥ 200 lines, extract ≥ 100 lines as a domain unit — %<extract>s
    3. Seat it in a readable tree by essence, goal, or component (git mv for moves/renames). Keep language pairs together; wire the build. Do not park another peer in a flat catch-all when a better home exists.
    4. When extracting, also reorganize related files into that directory if they belong with the new unit (same essence/goal/component) — git mv peers that are stranded in a flat parent or catch-all; keep language pairs together; wire the build.
    5. Keep behavior, public API, and readable formatting stable. Deleting blank lines or rewriting clear multi-line code into denser one-liners / chained statements does not count. Pre-existing size is not an excuse to skip.
    Skip only if shrinking would make the %<kind>s worse — say what you tried. "Needs a bigger refactor" is not a skip.
  MSG
  FOLLOWUP_RE = /
    Check\ if\ the\ issue\ is\ resolved\ fully\ and\ properly
    |Spec\ files\ edited\ in\ this\ session\ are\ longer\ than
    |Edited\ spec\ files\ \(longest\ first\)
    |Improve\ phrasing\ and\ synonym\ choice
    |db\/schema\.rb\ was\ edited
    |Edited\ production\ modules
    |modules\ were\ edited\ during\ this\ feature\ implementation
    |RuboCop\ auto-correct\ left\ remaining\ offenses
    |RuboCop\ Metrics\/AbcSize\ found\ methods
    |lizard\ found\ functions\ above\ the\ cyclomatic
    |Auto-commit\ skipped:
    |Warning\ in\ 
  /x
  READONLY = %w[
    Read ReadFile Grep Glob rg WebSearch WebFetch SemanticSearch
    GetMcpTools CallMcpTool FetchMcpResource AwaitShell Await
    TodoWrite UpdateCurrentStep AskQuestion SearchConversations
    SwitchMode Task Subagent ReadLints CreatePlan SetActiveBranch
    cursor-guide wc Kill
  ].to_set
  PROD_EXT = /
    \.(rs|rb|py|ts|tsx|js|jsx|mjs|cjs|go|swift|java|kt|kts|c|cc|cpp|cxx|
    h|hpp|hh|hxx|cs|php|scala|clj|ex|exs|hs|ml|mli|vue|svelte|
    ya?ml|css|scss|sass|slim|erb)$
  /ix
  MAIN_EXT = /
    \.(rs|rb|py|ts|tsx|js|jsx|mjs|cjs|go|swift|java|kt|kts|c|cc|cpp|cxx|
    h|hpp|cs|php|scala|clj|ex|exs|hs|ml|mli|vue|svelte|
    css|scss|sass|less|sql|sh|bash|zsh)$
  /ix
  SPEC_RE = %r{(^|/)(spec|specs|test|tests|__tests__|__mocks__|testdata|testing|fixtures)(/|$)}i
  SPEC_FILE_RE = %r{(^|/)(conftest\.py|test\.[^./]+|spec\.[^./]+)$}i
  SPEC_SUFFIX_RE = %r{([._-](spec|test|tests)|_(spec|test|tests))\.[^./]+$}i
  TEST_PREFIX_RE = %r{(^|/)test_[^/]+\.[^./]+$}i
  SCHEMA_SHELL_RE = %r{
    (^|[&;|\n]|&&)[[:space:]]*
    (cd[[:space:]]+\S+[[:space:]]+&&[[:space:]]+)*
    (bundle[[:space:]]+exec[[:space:]]+)?
    (bin/)?(rails|rake)[[:space:]]+
    (db:schema:dump|db:migrate|db:rollback|db:schema:load)
    (?:[[:space:]]|$|[&;|])
  }ix
  GIT_FLAGS = '(?:[[:space:]]+(?:-[A-Za-z0-9]+|--[A-Za-z0-9=-]+|--))*'
  EXTRACT_YAML = ['a separate YAML file named for the business concept (not *Part2*). Keep language pairs together.',
                  'YAML', 'keys'].freeze
  EXTRACT_CSS = ['a separate stylesheet named for the UI concept (not *Part2*). Prefer a component file.',
                 'stylesheet', 'rules'].freeze
  EXTRACT_TPL = ['a template partial named for the UI concept (not *Part2*). Keep copy in YAML.',
                 'template', 'markup'].freeze
  EXTRACT_CODE = ['a class/type with its own state and responsibility (not a free-function dump or *Part2*). ' \
                  'Name it for the business concept.', 'code', 'code'].freeze
  RUBOCOP_NOISE = /
    rubocop:\ command\ not\ found
    |Could\ not\ find.*(rubocop|gem)
    |Could\ not\ locate\ Gemfile
    |Install\ missing\ gems
    |Bundler\ can.t\ satisfy
  /ix
  LIZARD_READER = <<~PY
    from lizard_languages import get_reader_for
    import sys
    for path in sys.stdin:
        path = path.rstrip("\\n")
        if not path:
            continue
        reader = get_reader_for(path)
        if reader is None:
            continue
        if "ruby" in {n.lower() for n in reader.language_names}:
            continue
        print(path)
  PY
end
