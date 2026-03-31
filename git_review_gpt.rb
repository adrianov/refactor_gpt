#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/loader"
require "shellwords"
require "colorize"

DEFAULT_BASE = "origin/master"

def run_cmd(cmd)
  output = `#{cmd}`
  unless $?.success?
    warn "Command failed: #{cmd}".red
    exit 1
  end
  output
end

def git_root
  root = `git rev-parse --show-toplevel 2>/dev/null`.strip
  unless $?.success?
    puts "Not in a git repository.".red
    exit 1
  end
  root
end

def local_branches
  `git branch --format="%(refname:short)" 2>/dev/null`.split("\n").map(&:strip).reject(&:empty?)
end

def current_branch
  `git rev-parse --abbrev-ref HEAD 2>/dev/null`.strip
end

def parse_arguments(args)
  debug_mode = args.delete("--debug")
  remaining = args.reject { |a| a.start_with?("--") }
  branch = remaining[0]
  base = remaining[1]
  [!!debug_mode, branch, base]
end

def filter_branches(branches, filter)
  return branches if filter.nil? || filter.empty?

  branches.select { |b| b.include?(filter) }
end

def print_branch_list(branches, current)
  branches.each_with_index do |b, i|
    marker = b == current ? " (current)".yellow : ""
    puts "  #{i + 1}. #{b}#{marker}"
  end
end

def pick_from_matched(matched)
  return matched.first if matched.size == 1

  matched.each_with_index { |b, i| puts "  #{i + 1}. #{b}" }
  print "Enter number or name: ".white
  choice = $stdin.gets.to_s.strip
  idx = choice.to_i
  (idx >= 1 && idx <= matched.size) ? matched[idx - 1] : choice
end

def select_branch_interactively(branches, current)
  puts "Available branches (type to filter, Enter to confirm):".cyan
  print_branch_list(branches, current)
  puts
  print "Filter or select branch name: ".white
  input = $stdin.gets.to_s.strip
  return current if input.empty?

  matched = filter_branches(branches, input)
  return input if matched.empty?

  pick_from_matched(matched)
end

def resolve_branch(arg_branch, branches, current)
  return arg_branch if arg_branch && !arg_branch.empty?

  select_branch_interactively(branches, current)
end

def resolve_base(arg_base)
  return arg_base if arg_base && !arg_base.empty?

  DEFAULT_BASE
end

def fetch_mr_diff(branch, base)
  diff = `git diff -w -W --histogram #{Shellwords.escape(base)}...#{Shellwords.escape(branch)} 2>/dev/null`
  unless $?.success?
    puts "Failed to compute diff between #{base} and #{branch}.".red
    exit 1
  end
  diff
end

def recent_commits_on_branch(branch, base)
  `git log --pretty=%s #{Shellwords.escape(base)}..#{Shellwords.escape(branch)} 2>/dev/null`.strip
end

# Entry point
CompletionNotifier.setup_exit_hook

debug_mode, arg_branch, arg_base = parse_arguments(ARGV.dup)
Dir.chdir(git_root)

puts "Model: #{OpenAiClient.new(debug: debug_mode, progress_title: nil).model}".cyan

branches = local_branches
cur = current_branch
branch = resolve_branch(arg_branch, branches, cur)
base = resolve_base(arg_base)

puts
puts "Reviewing: #{branch} vs #{base}".cyan

diff = fetch_mr_diff(branch, base)

if diff.strip.empty?
  puts "No differences found between #{base} and #{branch}.".yellow
  exit 0
end

recent_commits = recent_commits_on_branch(branch, base)

result = MrReviewClient.new(debug: debug_mode).review(
  diff,
  branch: branch,
  base_branch: base,
  recent_commits: recent_commits
)

CompletionNotifier.notify_completion(success: true, title: "✓ MR Review Done")
MrReviewDisplay.display(result, branch: branch, base_branch: base)
