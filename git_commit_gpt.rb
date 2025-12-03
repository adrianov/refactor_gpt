#!/usr/bin/env ruby
require 'excon'
require 'oj'
require 'shellwords'
require 'English'
require 'ruby-progressbar'

# Class to interact with OpenAI API
class OpenAi
  def initialize
    @api_base_url = fetch_env('OPENAI_BASE_URL')
    @api_key = fetch_env('OPENAI_ACCESS_TOKEN')
    @model = 'gpt-5.1'
  end

  # Method to send prompts to OpenAI and get a response
  def ask(prompts)
    response = Excon.post(
      "#{@api_base_url}/chat/completions",
      headers: {
        'Content-Type' => 'application/json',
        'Authorization' => "Bearer #{@api_key}"
      },
      body: Oj.dump({ model: @model, messages: prompts }, mode: :compat),
      read_timeout: 100
    )
    answer = Oj.load(response.body).dig('choices', 0, 'message', 'content')
    handle_missing_answer(response) if answer.nil? || answer.empty?
    answer
  end

  # Method to generate grouped git add/commit commands based on git status and diff
  def commit_plan(status_output, diff_output, cli_hint, recent_commits, recent_commands)
    system_instruction = <<~HEREDOC
      You are a tool that groups changed files into meaningful git commits.

      Input:
      - `git status --porcelain` output (shows added, modified, deleted, renamed, untracked files)
      - unified git diff for all changes (including new files)
      - optional user-provided hints or preferences from the command line
      - last 5 git commit one-line messages to help you match existing style
      - last 5 shell commands from the user's terminal history to give you extra context

      Task:
      - Analyze the status and diff and infer logical groups of changes (by feature, bugfix, refactor, docs, tests, etc.).
      - Prefer commit messages that are consistent with the style of the provided recent commit messages.
      - Respect and incorporate the user-provided hints when choosing commit messages, grouping files, or prioritizing certain changes, as long as this does not conflict with the actual diffs.
      - For each group, produce:
        - a one-line, conventional-style commit message (no trailing period),
        - a list of file paths to include in that commit.
      - Every changed file from the status output must appear in exactly one group.
      - Use only relative file paths exactly as they appear in the status output (after the status flags).
      - Prefer a small number of coherent commits over many tiny ones.
      - Additionally, carefully review the provided diffs for potential errors or issues (such as obvious bugs, suspicious logic, or likely regressions).
      - If you detect any potential error in a file or diff hunk, include a warning entry describing:
        - the affected file path,
        - a short description of the possible error,
        - a probability (0.0–1.0) indicating how sure you are that this is a real issue.

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

    user_content = <<~HEREDOC
      Here is the git status (porcelain format):

      #{status_output}

      Here is the git diff for all changes:

      #{diff_output}

      Here are optional hints or preferences from the user (may be empty):

      #{cli_hint}

      Here are the last 5 git commit one-line messages (most recent first):

      #{recent_commits}

      Here are the last 5 shell commands from the user's terminal history (most recent last, if available):

      #{recent_commands}
    HEREDOC

    raw = ask([
      { role: 'system', content: system_instruction },
      { role: 'user', content: user_content }
    ])

    # Strip possible markdown fences before parsing JSON
    json_str = raw.gsub(/^```.*\n?/, '').gsub(/```$/, '').strip
    Oj.load(json_str)
  rescue Oj::ParseError
    puts "Failed to parse model response as JSON. Raw response:\n#{raw}"
    exit 1
  end

  private

  # Method to fetch environment variables
  def fetch_env(key, default = nil)
    @env_vars ||= load_env_vars
    value = @env_vars.fetch(key, ENV[key] || default)
    if value.nil?
      puts "Missing required environment variable: #{key}. Please add it to the .env file."
      exit 1
    end
    value
  end

  # Method to load environment variables from a file
  def load_env_vars
    env_file = File.join(File.dirname(__FILE__), '.env')
    return {} unless File.exist?(env_file)

    File.foreach(env_file).with_object({}) do |line, env_vars|
      key, value = line.split('=', 2)
      next unless key && value

      env_vars[key.strip] = value.strip
    end
  end

  # Method to handle missing answers in the response
  def handle_missing_answer(response)
    puts response.body
    exit 1
  end

  # Method to read system information
  def read_system_info
    File.exist?('/etc/os-release') ? File.read('/etc/os-release') : ''
  end
end

def run_cmd(cmd)
  output = `#{cmd}`
  unless $CHILD_STATUS&.success?
    puts "Command failed: #{cmd}"
    exit 1
  end
  output
end

cli_hint = ARGV.join(' ').to_s.strip

status_output = run_cmd('git status --porcelain')

if status_output.strip.empty?
  puts 'No changes to commit.'
  exit 0
end

diff_output = run_cmd('git diff')
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
  title: 'Planning commits',
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
  plan_raw = OpenAi.new.commit_plan(
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
  puts 'No commits suggested by the model.'
  exit 0
end

unless warnings.empty?
  puts "Warnings:\n\n"
  warnings.each do |warning|
    file = warning['file'].to_s
    description = warning['description'].to_s
    probability = warning['probability']
    probability_str = probability.nil? ? 'n/a' : probability.to_s
    puts "Warning in #{file}: #{description} (probability: #{probability_str})"
  end
  puts
end

puts "Planned commits:\n\n"
commits.each_with_index do |commit, idx|
  puts "Commit ##{idx + 1}: #{commit['message']}"
  Array(commit['files']).each do |file|
    puts "  - #{file}"
  end
  puts
end

puts 'Do you want to run these git add/commit commands? (y/n)'
answer = STDIN.gets.to_s.chomp.downcase

unless answer == 'y'
  puts 'Commands not executed.'
  exit 0
end

commits.each do |commit|
  files = Array(commit['files']).map(&:to_s).reject(&:empty?)
  next if files.empty?

  add_cmd = ['git', 'add', *files].map { |p| Shellwords.escape(p) }.join(' ')
  puts "Running: #{add_cmd}"
  system(add_cmd)

  commit_msg = commit['message'].to_s.strip
  next if commit_msg.empty?

  commit_cmd = "git commit -m #{Shellwords.escape(commit_msg)}"
  puts "Running: #{commit_cmd}"
  system(commit_cmd)
end
