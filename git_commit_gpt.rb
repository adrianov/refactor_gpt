#!/usr/bin/env ruby
require 'excon'
require 'oj'
require 'shellwords'
require 'ruby-progressbar'
require 'colorize'

class OpenAi
  DEFAULT_MODEL = 'gpt-5.1'
  REQUEST_TIMEOUT = 100
  ENV_FILE_PATH = File.join(__dir__, '.env')

  def initialize(model: DEFAULT_MODEL, debug: false)
    @api_base_url = fetch_env('OPENAI_BASE_URL')
    @api_key = fetch_env('OPENAI_ACCESS_TOKEN')
    @model = model
    @debug = debug
  end

  def ask(prompts)
    body = build_request_body(prompts)
    debug_request(body) if @debug

    response = make_api_request(body)
    handle_response_errors(response)
    extract_answer(response)
  rescue Excon::Error => e
    warn "HTTP request failed: #{e.class} - #{e.message}".red
    exit 1
  rescue Oj::ParseError => e
    warn "Failed to parse JSON response: #{e.message}".red
    warn response.body if defined?(response) && response&.body
    exit 1
  end

  def commit_plan(status_output, diff_output, cli_hint, recent_commits, recent_commands)
    user_content = build_user_content(status_output, diff_output, cli_hint, recent_commits, recent_commands)
    raw_response = ask([
                         { role: 'system', content: system_instruction },
                         { role: 'user', content: user_content }
                       ])
    parse_commit_plan_response(raw_response)
  end

  private

  def build_request_body(messages)
    { model: @model, messages: messages }
  end

  def debug_request(body)
    warn '--- OpenAI request payload (Ruby hash) ---'
    pretty_messages = body[:messages].map do |msg|
      if msg[:role] == 'system' && msg[:content].is_a?(String)
        { role: msg[:role], content_lines: msg[:content].split("\n") }
      else
        msg
      end
    end
    warn Oj.dump(body.merge(messages: pretty_messages), mode: :compat, indent: 2)
    warn '--- end payload ---'
  end

  def make_api_request(body)
    Excon.post(
      "#{@api_base_url}/chat/completions",
      headers: { 'Content-Type' => 'application/json', 'Authorization' => "Bearer #{@api_key}" },
      body: Oj.dump(body, mode: :compat),
      read_timeout: REQUEST_TIMEOUT
    )
  end

  def handle_response_errors(response)
    return if response.status == 200

    warn "OpenAI API request failed with status #{response.status}".red
    warn response.body
    exit 1
  end

  def extract_answer(response)
    answer = Oj.load(response.body).dig('choices', 0, 'message', 'content')
    return answer unless answer.nil? || answer.empty?

    warn 'No answer returned from OpenAI API. Full response body:'.red
    warn response.body
    exit 1
  end

  def build_user_content(status_output, diff_output, cli_hint, recent_commits, recent_commands)
    content_parts = []

    content_parts << "Here are hints or preferences from the user:\n\n#{cli_hint}\n" unless cli_hint.empty?

    content_parts.concat([
                           "Here is the git status:\n\n#{status_output}\n",
                           "Here is the git diff for all changes:\n\n#{diff_output}\n",
                           "Here are the last 5 git commit one-line messages (most recent first):\n\n#{recent_commits}\n"
                         ])

    unless recent_commands.empty?
      content_parts << "Here are the last 5 shell commands from the user's terminal history (most recent last):\n\n#{recent_commands}"
    end

    content_parts.join("\n")
  end

  def parse_commit_plan_response(raw_response)
    json_str = raw_response.gsub(/^```.*\n?/, '').gsub(/```$/, '').strip
    Oj.load(json_str)
  rescue Oj::ParseError
    puts "Failed to parse model response as JSON. Raw response:\n#{raw_response}".red
    exit 1
  end

  def load_agents_file
    agents_file = File.join(Dir.pwd, 'AGENTS.md')
    return '' unless File.exist?(agents_file)

    File.read(agents_file)
  rescue SystemCallError
    ''
  end

  def system_instruction
    agents_content = load_agents_file
    has_agents = !agents_content.empty?

    base_instruction = <<~HEREDOC
      You are a tool that groups changed files into meaningful git commits.

      Input:
      - `git status` output (shows current branch name, added, modified, deleted, renamed, untracked files)
      - unified git diff for all changes (including new files)
      - optional user-provided hints or preferences from the command line
      - last 5 git commit one-line messages to help you match existing style
      - last 5 shell commands from the user's terminal history to give you extra context
    HEREDOC

    base_instruction << "- Ruby development guidelines from AGENTS.md\n" if has_agents

    base_instruction << <<~HEREDOC

      Task:
      - Analyze the status and diff and infer logical groups of changes (by feature, bugfix, refactor, docs, tests, etc.).
      - Prefer commit messages that are consistent with the style of the provided recent commit messages.
      - Respect and incorporate the user-provided hints when choosing commit messages, grouping files, or prioritizing certain changes, as long as this does not conflict with the actual diffs.
      - Check the current branch name (available in git status output) and recent commit messages for JIRA task references (patterns like PT-4668, ABC-123, etc.).
      - If a JIRA task reference is found in the branch name or recent commits, use the same reference format at the beginning of commit messages (e.g., "[PT-4668] type: short description").
      - For each group, produce:
        - a one-line, conventional-style commit message (no trailing period) that describes the specific atomic change,
        - For English: Focus on concrete actions: "add X", "fix Y", "remove Z", "update A", "refactor B", "extract C", "move D"
        - For Russian: Use отглагольные существительные (verbal nouns) instead of infinitive verbs
        - Instead of "добавить X" → "добавление X"
        - Instead of "исправить Y" → "исправление Y"#{' '}
        - Instead of "удалить Z" → "удаление Z"
        - Instead of "обновить A" → "обновление A"
        - Instead of "рефакторить B" → "рефакторинг B"
        - Instead of "извлечь C" → "извлечение C"
        - Instead of "переместить D" → "перемещение D"
        - Avoid vague phrases like "стабилизация", "оптимизация", "улучшение", "обновление", "исправление проблем"
        - Instead of "стабилизировать виджет" → "фиксация рендеринга виджета при прокрутке"
        - Instead of "исправить время" → "фиксация расчета времени в тесте"
        - Be specific about what changed and why
        - a list of file paths to include in that commit.
      - Every changed file from the status output must appear in exactly one group.
      - Use only relative file paths exactly as they appear in the status output (after the status flags).
      - Prefer a small number of coherent commits over many tiny ones.
      - Additionally, carefully review the provided diffs for potential errors or issues (such as obvious bugs, suspicious logic, or likely regressions)#{has_agents ? ' based on the development guidelines provided in AGENTS.md' : ''}.
      - If you detect any potential error in a file or diff hunk, include a warning entry describing:
        - the affected file path,
        - a short description of the possible error,
        - a probability (0.0–1.0) indicating how sure you are that this is a real issue.
    HEREDOC

    if has_agents
      base_instruction << <<~HEREDOC

        AGENTS.md content (development guidelines to follow):
        #{agents_content}
      HEREDOC
    end

    base_instruction << <<~HEREDOC

      Output format (strict JSON):
      {
        "commits": [
          {
            "message": "type: short description",
            "files": ["path/one.rb", "path/two.rb"]
          }
        ],
        "warnings": [
          {
            "file": "path/one.rb",
            "description": "Possible off-by-one error in loop bounds",
            "probability": 0.8
          }
        ]
      }

      If you do not see any likely errors, return "warnings": [].

      Do not include any text outside of the JSON.
    HEREDOC

    base_instruction
  end

  def fetch_env(key, default = nil)
    @env_vars ||= load_env_vars
    value = @env_vars.fetch(key, ENV[key] || default)
    return value unless value.nil?

    warn("Missing required environment variable: #{key}. Please add it to the .env file.".red)
    exit 1
  end

  def load_env_vars
    return {} unless File.exist?(ENV_FILE_PATH)

    File.foreach(ENV_FILE_PATH).with_object({}) do |line, env_vars|
      line = line.strip
      next if line.empty? || line.start_with?('#')

      key, value = line.split('=', 2)
      next unless key && value

      env_vars[key.strip] = value.strip
    end
  end
end

def run_cmd(cmd, capture_output: true)
  if capture_output
    output = `#{cmd}`
    unless $?.success?
      warn "Command failed: #{cmd}".red
      exit 1
    end
    output
  else
    system(cmd)
    unless $?.success?
      warn "Command failed: #{cmd}".red
      exit 1
    end
  end
end

# Parse arguments for debug mode
debug_mode = false
cli_hint_parts = []

ARGV.each do |arg|
  case arg
  when '--debug' then debug_mode = true
                      next
  end
  cli_hint_parts << arg
end

cli_hint = cli_hint_parts.join(' ').to_s.strip

status_output = run_cmd('git status')

if status_output.strip.empty? || status_output.include?('nothing to commit') || status_output.include?('working tree clean')
  puts 'No changes to commit.'.yellow
  exit 0
end

recent_commits = run_cmd('git log -5 --pretty=%s')
recent_commands = begin
  history_file = ENV['HISTFILE'] || File.expand_path('~/.bash_history')
  if File.exist?(history_file)
    lines = File.readlines(history_file, chomp: true)
    lines.last(5).join("\n")
  else
    ''
  end
end

# Check if last command was git diff to avoid showing it twice
last_command_was_git_diff = recent_commands.lines.last&.strip&.start_with?('git diff')

unless last_command_was_git_diff
  puts "\nCurrent changes:\n".cyan
  run_cmd('git diff', capture_output: false)
  puts "\n"
end

# Capture diff output for OpenAI analysis
diff_output = `git diff`
unless $?.success?
  warn 'Failed to capture diff for analysis'.red
  exit 1
end

combined_input = [
  status_output,
  diff_output,
  cli_hint,
  recent_commits,
  recent_commands
].join("\n\n")

total_size = [combined_input.bytesize, 1000].max
start_time = Time.now

PROGRESS_SPEED_FILE = File.join(Dir.home, '.refactor_gpt')

def load_progress_speed(progress_speed_file)
  return 300 unless File.exist?(progress_speed_file)

  value = File.read(progress_speed_file).to_f
  return 300 if value <= 0

  value
rescue SystemCallError, ArgumentError
  300
end

PROGRESS_SPEED = load_progress_speed(PROGRESS_SPEED_FILE)

progressbar = ProgressBar.create(
  title: 'Planning commits'.cyan,
  total: total_size,
  format: '%t: |%B| %p%% %e',
  length: 60
)

progress_thread = Thread.new do
  loop do
    elapsed_time = Time.now - start_time
    progress = [(elapsed_time * PROGRESS_SPEED).round, total_size].min
    progressbar.progress = progress
    break if progress >= total_size || progressbar.finished?

    sleep 0.1
  end
end

plan_raw = nil
begin
  plan_raw = OpenAi.new(debug: debug_mode).commit_plan(
    status_output,
    diff_output,
    cli_hint,
    recent_commits,
    recent_commands
  )
ensure
  progressbar.finish unless progressbar.finished?
  progress_thread.join
end

end_time = Time.now
elapsed_time = end_time - start_time
plan_size = plan_raw.to_s.bytesize
speed = plan_size.positive? && elapsed_time.positive? ? plan_size / elapsed_time : 0

begin
  File.write(PROGRESS_SPEED_FILE, speed.round(2).to_s) if speed.positive?
rescue SystemCallError
  # ignore persistence errors
end

plan = plan_raw
commits = plan['commits'] || []
warnings = plan['warnings'] || []

if commits.empty?
  puts 'No commits suggested by the model.'.yellow
  exit 0
end

unless warnings.empty?
  puts "Warnings:\n\n".yellow
  warnings.each do |warning|
    file = warning['file'].to_s
    description = warning['description'].to_s
    probability = warning['probability']
    probability_str = probability.nil? ? 'n/a' : probability.to_s
    puts "Warning in #{file}: #{description} (probability: #{probability_str})".yellow
  end
  puts
end

puts "Planned commits:\n\n".cyan
commits.each_with_index do |commit, idx|
  puts "Commit ##{idx + 1}: #{commit['message']}".cyan
  Array(commit['files']).each do |file|
    puts "  - #{file}".blue
  end
  puts
end

puts 'Do you want to run these git add/commit commands? (y/N)'.white
answer = STDIN.gets.to_s.chomp.downcase

unless answer == 'y'
  puts 'Commands not executed.'.yellow
  exit 0
end

commits.each do |commit|
  files = Array(commit['files']).map(&:to_s).reject(&:empty?)
  next if files.empty?

  add_cmd = ['git', 'add', *files].map { |p| Shellwords.escape(p) }.join(' ')
  puts "Running: #{add_cmd}".green
  system(add_cmd)

  commit_msg = commit['message'].to_s.strip
  next if commit_msg.empty?

  commit_cmd = "git commit -m #{Shellwords.escape(commit_msg)}"
  puts "Running: #{commit_cmd}".green
  system(commit_cmd)
end

puts 'Do you want to push? (y/N)'.white
push_answer = STDIN.gets.to_s.chomp.downcase

if push_answer == 'y'
  puts 'Running: git push'.green
  system('git push')
else
  puts 'Changes committed but not pushed.'.yellow
end
