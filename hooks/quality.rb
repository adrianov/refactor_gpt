#!/usr/bin/env -S ruby --disable-gems
# frozen_string_literal: true
#
# Cursor stop pipeline (rbenv/Homebrew/system Ruby via PATH).
# Stages: formal → review → document → git_commit_gpt. One follow-up per stop.
#
# 1. Change detection: git is the source of truth. Every stop reports each
#    workspace root's uncommitted work vs HEAD plus untracked files; roots
#    outside any repo are skipped. No snapshots or state files involved.
# 2. Formal: plain `abcop` per touched repo over the current-MR scope — it owns
#    method/module ABC size and variable hygiene. Failures retry this stage
#    after the agent fixes them.
# 3. Review: completion check and scatter (once per cycle; reset if formal
#    or commit complains). Re-emit is skipped when the edited-module count
#    is unchanged since the last scatter. schema.rb: own-repo remotes exempt.
# 4. Document: wording for new .md files only, once, right before commit.
#    Edits to existing .md skip this stage. Markdown-only edits continue to
#    commit. A full cycle restart can reach this stage again.
# 5. git_commit_gpt --auto on the whole repo (push when QUALITY_OWN_GITHUB
#    matches the origin owner). An exclusive lock keyed by git-root path
#    gates the whole stop-hook run (one agent per project at a time).
#    Warnings go back to 1 after the fix; a clean run stops.
#
# Optional env:
#   QUALITY_OWN_GITHUB   — GitHub username/org; owned remotes get --push, and
#                          the schema.rb minimal-change note applies to other
#                          remotes only
#   QUALITY_LOCAL        — optional extra Ruby file after public modules
#                          (default: ~/.cursor/hooks/quality_local.rb if present)
#
# Implementation lives in hooks/quality/*.rb (Quality::* modules).

require 'json'
require 'fileutils'
require 'digest'

require_relative 'quality/config'
require_relative 'quality/support'
require_relative 'quality/state_store'
require_relative 'quality/transcripts'
require_relative 'quality/git_changes'
require_relative 'quality/formal'
require_relative 'quality/commit'
require_relative 'quality/review'
require_relative 'quality/stages'

local = ENV['QUALITY_LOCAL'].to_s
local = File.join(ENV['HOME'].to_s, '.cursor/hooks/quality_local.rb') if local.empty?
require local if File.file?(local)

# Cursor stop-hook entry: wires Quality::* mixins and runs the pipeline.
class QualityHook
  include Quality::Support
  include Quality::StateStore
  include Quality::Transcripts
  include Quality::GitChanges
  include Quality::Formal
  include Quality::CommitStage
  include Quality::Review
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
    return stalled_followup(msg) if stalled_repeat?(msg)

    bump_repeat(msg)
    FileUtils.mkdir_p(Quality::STATE)
    File.write(pending_file, msg)
    puts JSON.generate('followup_message' => msg)
    # Must return truthy: run_stages does `return msg if msg`. puts returns nil,
    # so a nil here used to keep the pipeline going and finish_empty overwrote
    # the followup with `{}` (verify / lint / etc. never reached the agent).
    msg
  end

  # Breaker against endless re-emission of an identical followup: when nothing
  # progresses between deliveries (e.g. a rate-limited provider kills every
  # turn before the agent can act), resending the same message loops forever.
  # Trips mid-chain only; FOLLOWUP_REPEATS deliveries get through, then the
  # cycle is dropped silently for the agent to resume with the next user input.
  # Chain state comes from followup_chain? (loop_count flag, stored-pending
  # match, or FOLLOWUP_RE): omp never sets Cursor's stop_hook_active, so
  # gating on loop_count alone left this permanently disarmed under omp and
  # an idle provider loop re-emitted one identical message 27 times.
  def stalled_repeat?(msg)
    return false unless @input['loop_count'].to_i != 0 || followup_chain?

    digest, count = load_repeat
    digest == Digest::SHA256.hexdigest(msg) && count >= Quality::FOLLOWUP_REPEATS
  end

  def bump_repeat(msg)
    digest = Digest::SHA256.hexdigest(msg)
    prev, count = load_repeat
    save_repeat(digest, prev == digest ? count + 1 : 1)
  end

  def stalled_followup(msg)
    _, count = load_repeat
    log_action('followup_stalled', repeats: count, head: msg[0, 80])
    clear_stage
    clear_repeat
    release_active
    empty
    throw :stalled
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
