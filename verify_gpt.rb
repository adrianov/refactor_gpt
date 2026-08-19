#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/loader"
require "shellwords"
require "colorize"

PROJECT_ROOT = Dir.pwd.freeze

def run_cmd(cmd, capture_output: true, project_root: PROJECT_ROOT)
  git_cmd = cmd.start_with?("git ") ? "git -C #{Shellwords.escape(project_root)} #{cmd[4..-1]}" : cmd
  if capture_output
    output = `#{git_cmd}`
    unless $?.success?
      puts "NO: Command failed: #{git_cmd}"
      exit 1
    end
    output
  else
    system(git_cmd)
    unless $?.success?
      puts "NO: Command failed: #{git_cmd}"
      exit 1
    end
  end
end

def parse_arguments(args)
  debug_mode = args.include?("--debug")
  rest = args.reject { |arg| arg == "--debug" }
  leftover, paths = CliPaths.partition(rest)
  paths = CliPaths.select_supported(paths, DiffProcessor::CODE_EXTENSIONS)
  [debug_mode, leftover.join(" ").strip, paths]
end

def read_feature_request_from_stdin
  $stdin.read.to_s.strip unless $stdin.tty?
end

def get_feature_request(hint)
  return hint unless hint.empty?

  stdin_request = read_feature_request_from_stdin
  return stdin_request if stdin_request && !stdin_request.empty?

  exit 0
end

def parse_response(response)
  return result_unparseable(response) if response.nil? || response.to_s.strip.empty?

  # Strip only leading/trailing so newlines are preserved; verdict uses start or \bYES/\bNO anywhere.
  normalized = response.to_s.strip
  verdict = response_verdict(normalized)
  return result_parsed_yes(normalized) if verdict == :yes
  return result_parsed_no(normalized) if verdict == :no

  result_unparseable(response)
end

def result_unparseable(raw_llm_response)
  {
    verified: false,
    display_message: 'LLM response could not be parsed',
    raw_response: raw_llm_response
  }
end

def result_parsed(verified, brief_description)
  { verified: verified, display_message: brief_description, raw_response: nil }
end

def result_parsed_yes(normalized)
  brief = extract_brief_after_yes(normalized)
  result_parsed(true, brief.empty? ? "Verification passed" : brief)
end

def result_parsed_no(normalized)
  brief = extract_brief_after_no(normalized)
  result_parsed(false, brief.empty? ? "Verification failed" : brief)
end

MAX_BRIEF_LENGTH = 200

def extract_brief_after_yes(normalized)
  match = normalized.match(/\bYES\s*:?\s*(.*)/im)
  brief = match ? match[1].to_s.strip : ''
  first_line_brief(brief)
end

def extract_brief_after_no(normalized)
  match = normalized.match(/\bNO\s*:?\s*(.*)/im)
  brief = match ? match[1].to_s.strip : ''
  first_line_brief(brief)
end

def first_line_brief(text)
  line = text.each_line.first
  line = line ? line.to_s.strip : ''
  line.length > MAX_BRIEF_LENGTH ? "#{line[0, MAX_BRIEF_LENGTH]}..." : line
end

def response_verdict(normalized)
  upcased = normalized.upcase
  return :yes if upcased.start_with?("YES")
  return :no if upcased.start_with?("NO")

  yes_match = upcased.match(/\bYES\s*:?/i)
  no_match = upcased.match(/\bNO\s*:?/i)
  return :no if no_match && (yes_match.nil? || no_match.begin(0) < yes_match.begin(0))
  return :yes if yes_match && (no_match.nil? || yes_match.begin(0) < no_match.begin(0))

  nil
end

def display_result(result)
  if result[:verified]
    puts "YES: #{result[:display_message]}"
    exit 0
  end

  puts "NO: Unable to parse assessment response. The LLM response did not contain YES or NO."
  print_actual_llm_response_block(result[:raw_response] || result[:display_message])
  exit 1
end

def print_actual_llm_response_block(content)
  return if content.nil? || content.to_s.strip.empty?

  puts "\nActual LLM response:"
  content.each_line { |line| puts line.chomp }
  puts "\nFull response length: #{content.length} characters"
end

def prepare_untracked_files(project_root: PROJECT_ROOT, pathspecs: [])
  files_to_add = untracked_intent_paths(project_root, pathspecs)
  return if files_to_add.empty?

  add_cmd = ["git", "-C", project_root, "add", "-N", *files_to_add].map { |p| Shellwords.escape(p) }.join(" ")
  system("#{add_cmd} 2>/dev/null")
end

def untracked_intent_paths(project_root, pathspecs)
  spec = GitPathspec.args(pathspecs)
  cmd = ["git", "-C", project_root, "ls-files", "--others", "--exclude-standard", *spec].shelljoin
  listed = `#{cmd}`.split("\n")
  unless $?.success?
    puts "NO: Failed to list untracked files"
    exit 1
  end

  listed.reject { |file| GitCommitExecutor.ephemeral_path?(file) }
end

def get_diff_output(project_root: PROJECT_ROOT, pathspecs: [])
  spec = GitPathspec.args(pathspecs)
  diff_output = `git -C #{Shellwords.escape(project_root)} diff -U500 #{spec.shelljoin}`
  unless $?.success?
    puts "NO: Failed to capture diff for analysis"
    exit 1
  end
  diff_output
end

CompletionNotifier.setup_exit_hook

debug_mode, cli_hint, paths = parse_arguments(ARGV)
feature_request = get_feature_request(cli_hint)
spec = GitPathspec.args(paths)

status_output = run_cmd(["git", "status", "--porcelain", "--branch", *spec].shelljoin)

  if status_output.lines.count { |line| !line.start_with?("##") }.zero?
    puts "NO: No changes to assess."
    exit 1
  end

  prepare_untracked_files(pathspecs: paths)
  diff_output = get_diff_output(pathspecs: paths)

  response = Verify.new(debug: debug_mode, project_root: PROJECT_ROOT).assess_feature(
    feature_request,
    status_output,
    diff_output
  )

  result = parse_response(response)
  display_result(result)
