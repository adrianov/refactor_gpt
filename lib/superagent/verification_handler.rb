# frozen_string_literal: true

require 'shellwords'
require_relative "../agents_file_handler"
require_relative "../diff_processor"

# Handles verification prompts and response parsing
class VerificationHandler
  include AgentsFileHandler

  MAX_CONTENT_SIZE_KB = 100

  def initialize(display, agent_executor)
    @display = display
    @agent_executor = agent_executor
    @diff_processor = DiffProcessor.new
  end

  def build_fix_prompt(req)
    <<~HEREDOC
      Original request: #{req}

      The previous attempt failed. Please fix the implementation.

      Review the codebase and make the necessary corrections.
    HEREDOC
  end

  def parse_res(res)
    return [false, res] if res.nil? || res.strip.empty?

    n = normalize_response(res)
    up = n.upcase

    # Prioritize NO if both are present and NO comes first
    yes_match = up.match(/\bYES\b/i)
    no_match = up.match(/\bNO\b/i)

    if no_match && (yes_match.nil? || no_match.begin(0) < yes_match.begin(0))
      parse_no_res(n)
    elsif yes_match
      parse_yes_res(n)
    else
      [false, res]
    end
  end

  def normalize_response(res)
    normalized = res.strip
    normalized = normalized.gsub(/\*\*(.*?)\*\*/, '\1')
    normalized = normalized.gsub(/\*(.*?)\*/, '\1')
    normalized = normalized.gsub(/__(.*?)__/, '\1')
    normalized = normalized.gsub(/_(.*?)_/, '\1')
    normalized.strip
  end

  def parse_no_res(n)
    m = n.match(/\bNO\b\s*:?\s*(.*)/i)
    description = m ? m[1].strip : ''
    [false, description.empty? ? 'Failed' : description]
  end

  def parse_yes_res(n)
    m = n.match(/\bYES\b\s*:?\s*(.*)/i)
    description = m ? m[1].strip : ''
    [true, description.empty? ? 'Passed' : description]
  end

  def git_repo?
    @display.git_repo?
  end

  def collect_git_status
    return '' unless git_repo?

    output = `git status --porcelain --branch 2>&1`
    unless $?.success?
      @display.puts 'Warning: Failed to get git status'.yellow
      return ''
    end
    output
  end

  def prepare_untracked_files
    return unless git_repo?

    all_untracked = `git ls-files --others --exclude-standard 2>&1`.split("\n")
    additional_exclusions = [
      '*.log', '*.tmp', '*.temp', '*.bak', '*.swp', '*.swo',
      '*.pyc', '*.pyo', '*.class', '*.jar', '*.war', '*.ear',
      '*.zip', '*.tar.gz', '*.tgz', '*.rar', '*.exe', '*.dll',
      '*.so', '*.dylib', '*.bin', '*.dat', '*.orig', '*.rej',
      '.DS_Store', 'Thumbs.db'
    ]
    files_to_add = all_untracked.reject do |file|
      additional_exclusions.any? { |pattern| File.fnmatch(pattern, File.basename(file)) }
    end

    return if files_to_add.empty?

    add_cmd = ['git', 'add', '-N', *files_to_add].map { |p| Shellwords.escape(p) }.join(' ')
    system("#{add_cmd} 2>/dev/null")
  end

  def collect_git_diff
    return '' unless git_repo?

    output = `git diff -U500 2>&1`
    unless $?.success?
      @display.puts 'Warning: Failed to get git diff'.yellow
      return ''
    end
    output
  end

  def collect_file_contents
    return '' if git_repo?

    @display.puts 'No git repository detected, collecting file contents...'.yellow

    exclusions = [
      '*.log', '*.tmp', '*.temp', '*.bak', '*.swp', '*.swo',
      '*.pyc', '*.pyo', '*.class', '*.jar', '*.war', '*.ear',
      '*.zip', '*.tar.gz', '*.tgz', '*.rar', '*.exe', '*.dll',
      '*.so', '*.dylib', '*.bin', '*.dat', '*.orig', '*.rej',
      '.DS_Store', 'Thumbs.db', '.git', '.gitignore'
    ]

    code_extensions = %w[
      .rb .py .js .ts .jsx .tsx .java .php .cpp .c .h .hpp .go .rs
      .sh .bash .zsh .html .css .scss .sass .yml .yaml .json .xml
      .erb .slim .swift .kt .scala .pl .pm .r .jl .md .txt
    ]

    files_content = []
    current_dir = Dir.pwd

    Dir.glob(File.join(current_dir, '**', '*')).each do |file_path|
      next unless File.file?(file_path)

      relative_path = file_path.sub("#{current_dir}/", '')
      basename = File.basename(relative_path)

      next if exclusions.any? { |pattern| File.fnmatch(pattern, basename) }
      next unless code_extensions.any? { |ext| relative_path.end_with?(ext) } ||
                  basename.start_with?('README') || basename == 'Makefile' || basename == 'Rakefile'

      begin
        content = File.read(file_path)
        files_content << "=== File: #{relative_path} ===\n#{content}\n"
      rescue StandardError => e
        @display.puts "Warning: Failed to read #{relative_path}: #{e.message}".yellow
      end
    end

    files_content.join("\n")
  end

  def build_verification_system_instruction
    agents_content = load_agents_file
    has_agents = !agents_content.empty?

    instruction_parts = [
      <<~HEREDOC
        You are a tool that verifies whether code changes fully implement a requested feature.
      HEREDOC
    ]

    instruction_parts << "- Ruby development guidelines from AGENTS.md\n" if has_agents

    instruction_parts << <<~HEREDOC

      Task:
      Verify that the code changes fully implement the user's request without introducing bugs or regressions.

      Available information:
      - Git status and diff are provided in the prompt below (if git repository exists)
      - File contents are provided if no git repository is detected
      - Analyze the provided changes to verify they meet the requirements
      - Do not run any commands - all necessary data is already included

      Verification approach:
      - Review the git diff (or file contents if no git) to understand what changed
      - Check if the changes address the user's request
      - Look for potential bugs, regressions, or missing functionality
      - Verify code quality and adherence to project guidelines

      Response format:
      - Start your response with "YES: " followed by a brief description if verification passes
      - Start your response with "NO: " followed by a brief description if verification fails

      CRITICAL requirements:
      - Your response MUST start with either "YES" or "NO" as the first word
      - Use minimal formatting only - avoid excessive markdown or formatting
      - Keep your response short and concise - one sentence is sufficient
      - The description after YES/NO should be brief and specific
    HEREDOC

    if has_agents
      instruction_parts << <<~HEREDOC

        AGENTS.md content (development guidelines to consider):
        #{agents_content}
      HEREDOC
    end

    instruction_parts.join
  end

  def build_verification_user_content(user_request, status_output, diff_output, file_contents = '')
    content_parts = []
    current_size_bytes = 0
    max_size_bytes = MAX_CONTENT_SIZE_KB * 1024

    request_text = "User request: #{user_request}\n\n"
    current_size_bytes = append_section(content_parts, current_size_bytes, max_size_bytes, request_text)

    if git_repo?
      status_text = "Here is the git status:\n#{status_output.strip}\n\n"
      current_size_bytes = append_section(content_parts, current_size_bytes, max_size_bytes, status_text)

      unless diff_output.strip.empty?
        append_diff_section(content_parts, current_size_bytes, max_size_bytes, diff_output, 
status_output)
      end
    else
      no_git_text = "No git repository detected. Here are the file contents:\n\n"
      current_size_bytes = append_section(content_parts, current_size_bytes, max_size_bytes, no_git_text)

      unless file_contents.strip.empty?
        append_file_contents_section(content_parts, current_size_bytes, max_size_bytes, 
file_contents)
      else
        append_section(content_parts, current_size_bytes, max_size_bytes, 
"No files found to verify.")
      end
    end

    content_parts.join("\n")
  end

  def build_verification_prompt(req)
    status_output = collect_git_status
    prepare_untracked_files
    diff_output = collect_git_diff
    file_contents = collect_file_contents

    user_content = build_verification_user_content(req, status_output, diff_output, file_contents)

    <<~HEREDOC
      #{build_verification_system_instruction}

      ---

      #{user_content}
    HEREDOC
  end

  def run_verification(model, req)
    $stdout.puts ''
    @display.puts 'Verifying...'.blue

    verification_prompt = build_verification_prompt(req)
    success, output = @agent_executor.run(model, verification_prompt, verification_mode: true)
    return [false, 'Verification failed'] unless success

    verified, desc = parse_res(output.strip)
    [verified, desc || 'Failed']
  end

  def retry_with_fix(model, req)
    fix_prompt = build_fix_prompt(req)
    @display.puts "Retrying #{model} with fix...".blue
    $stdout.puts ''

    success, _output = @agent_executor.run(model, fix_prompt)
    return [false, nil] unless success

    run_verification(model, req)
  end

  private

  def append_section(parts, current_size_bytes, max_size_bytes, text)
    return current_size_bytes if text.empty? || current_size_bytes + text.bytesize > max_size_bytes

    parts << text
    current_size_bytes + text.bytesize
  end

  def append_diff_section(parts, current_size_bytes, max_size_bytes, diff_output, status_output)
    diff_text = "Here is the git diff for all changes:\n\n"
    remaining = max_size_bytes - current_size_bytes - diff_text.bytesize
    if remaining > 0
      sorted_diff = @diff_processor.build_sorted_diff(diff_output, status_output, remaining)
      diff_text += sorted_diff
      parts << diff_text
      current_size_bytes + diff_text.bytesize
    else
      parts << "#{diff_text}(Diff truncated: exceeds #{MAX_CONTENT_SIZE_KB} KB limit)\n"
      current_size_bytes
    end
  end

  def append_file_contents_section(parts, current_size_bytes, max_size_bytes, file_contents)
    remaining = max_size_bytes - current_size_bytes
    return current_size_bytes if remaining <= 0

    if file_contents.bytesize <= remaining
      parts << file_contents.strip
      current_size_bytes + file_contents.bytesize
    else
      truncated = truncate_file_contents(file_contents, remaining)
      parts << truncated
      current_size_bytes + truncated.bytesize
    end
  end

  def truncate_file_contents(file_contents, max_bytes)
    return '' if max_bytes <= 0

    truncated = file_contents.byteslice(0, max_bytes)
    last_newline = truncated.rindex("\n")
    return truncated if last_newline.nil?

    "#{truncated.byteslice(0, last_newline + 1)}\n... (file contents truncated due to size limit)\n"
  end
end
