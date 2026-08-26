#!/usr/bin/env -S ruby --disable-gems
# frozen_string_literal: true
#
# Cursor stop pipeline (rbenv/Homebrew/system Ruby via PATH).
# Stages: formal → review → document → git_commit_gpt. One follow-up per stop.
#
# 1. Collect files edited after the last user message.
# 2. Formal: abcop (ABC size, single-use variables; changed functions vs HEAD
#    only), and ≥200-line spec/module extraction only when origin matches
#    QUALITY_OWN_GITHUB (same gate as --push). Failures retry this stage
#    after the agent fixes them.
# 3. Review: completion check and scatter (once per cycle; reset if formal
#    or commit complains), plus schema.rb (own-repo remotes exempt).
# 4. Document: wording for new .md files only, once, right before commit.
#    Edits to existing .md skip this stage. Markdown-only edits continue to
#    commit. A full cycle restart can reach this stage again.
# 5. git_commit_gpt --auto on the whole repo (push when QUALITY_OWN_GITHUB
#    matches the origin owner), only when this is the last active quality
#    run for the git root. Concurrent agents leave an active lock for the
#    cycle; the last one out commits. Warnings go back to 1 after the fix;
#    a clean run stops.
#
# Optional env:
#   GIT_COMMIT_GPT       — path to git_commit_gpt.rb (default: ../../git_commit_gpt.rb)
#   QUALITY_OWN_GITHUB   — GitHub username/org; when set, owned remotes get
#                          --push, AbcSize, and ≥200-line spec/module
#                          extraction; the schema.rb minimal-change note
#                          applies to other remotes only
#   QUALITY_LOCAL        — optional extra Ruby file after public modules
#                          (default: ~/.cursor/hooks/quality_local.rb if present)
#
# Implementation lives in hooks/quality/*.rb (Quality::* modules).

require 'json'
require 'fileutils'

require_relative 'quality/config'
require_relative 'quality/support'
require_relative 'quality/state_store'
require_relative 'quality/turn_files'
require_relative 'quality/formal'
require_relative 'quality/stages'

local = ENV['QUALITY_LOCAL'].to_s
local = File.join(ENV['HOME'].to_s, '.cursor/hooks/quality_local.rb') if local.empty?
require local if File.file?(local)

# Cursor stop-hook entry: wires Quality::* mixins and runs the pipeline.
class QualityHook
  include Quality::Support
  include Quality::StateStore
  include Quality::TurnFiles
  include Quality::Formal
  include Quality::Stages

  def initialize(input)
    @input = input.is_a?(Hash) ? input : {}
    @roots = workspace_roots_from(@input)
    @tmpdir = (ENV['TMPDIR'] || '/tmp').chomp('/')
    @conversation_id = @input['conversation_id'].to_s
    @transcript_path = @input['transcript_path'].to_s
    @session_key = session_key_from(@conversation_id, @transcript_path)
    bootstrap_path
  end

  def run
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @input['status'] ? stop_pipeline : empty
  rescue StandardError => e
    STDERR.puts "[quality] #{e.class}: #{e.message}\n#{e.backtrace.first(6).join("\n")}"
    empty
  ensure
    log_pipeline_duration(t0)
  end

  def log_pipeline_duration(t0)
    return unless @input['status']

    ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
    log_action('pipeline_done', ms: ms)
  end

  private

  def workspace_roots_from(input)
    roots = Array(input['workspace_roots']).map { |r| r.to_s.sub(%r{/$}, '') }
    roots << ENV['CURSOR_PROJECT_DIR'].to_s.sub(%r{/$}, '') if roots.empty?
    roots.reject { |r| r.nil? || r.empty? }
  end

  def session_key_from(conversation_id, transcript_path)
    key = conversation_id
    key = File.basename(transcript_path, '.jsonl') if key.empty? && !transcript_path.empty?
    key.to_s.gsub(/[^A-Za-z0-9._-]/, '_')
  end

  def bootstrap_path
    # rbenv exec exports RBENV_VERSION and RBENV_DIR for its child; without
    # this every shim we spawn would run the hook interpreter's ruby resolved
    # from the launch dir instead of each root's .ruby-version pin (e.g.
    # a spawned ruby script resolving against a foreign lockfile).
    %w[RBENV_VERSION RBENV_DIR].each { |k| ENV.delete(k) }
    ENV['PATH'] = (path_extras + [ENV['PATH'] || '/usr/bin:/bin']).join(':')
  end

  def path_extras
    home = ENV['HOME'].to_s
    ["#{home}/.rbenv/shims", "#{home}/.rbenv/bin", '/opt/homebrew/bin', "#{home}/.local/bin"]
      .select { |d| File.directory?(d) }
  end

  def empty
    puts '{}'
  end

  def followup(msg)
    msg = rel_project_text(msg.to_s)
    FileUtils.mkdir_p(Quality::STATE)
    File.write(pending_file, msg)
    puts JSON.generate('followup_message' => msg)
    # Must return truthy: run_stages does `return msg if msg`. puts returns nil,
    # so a nil here used to keep the pipeline going and finish_empty overwrote
    # the followup with `{}` (verify / lint / etc. never reached the agent).
    msg
  end

  def completed?
    @input['status'].to_s == 'completed'
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    raw = STDIN.read
    input = raw.to_s.strip.empty? ? {} : JSON.parse(raw)
    QualityHook.new(input).run
  rescue StandardError => e
    STDERR.puts "[quality] #{e.class}: #{e.message}"
    puts '{}'
  end
end
