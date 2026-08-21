#!/usr/bin/env -S ruby --disable-gems
# frozen_string_literal: true
#
# Cursor stop pipeline (rbenv/Homebrew/system Ruby via PATH).
# Stages: formal → review → document → git_commit_gpt. One follow-up per stop.
#
# 1. Collect files edited after the last user message.
# 2. Formal: RuboCop, AbcSize, lizard; ≥200-line spec/module extraction only
#    when origin matches QUALITY_OWN_GITHUB (same gate as --push). Failures
#    retry this stage after the agent fixes them.
# 3. Review: completion check and scatter (once per cycle; reset if formal
#    or commit complains), plus schema.rb.
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
#                          --push and ≥200-line spec/module extraction
#   QUALITY_RUBOCOP_DOCKER=1 — run RuboCop via docker compose for matching apps
#   QUALITY_RUBOCOP_DOCKER_SERVICE  — compose service name (required when docker on)
#   QUALITY_RUBOCOP_DOCKER_BASENAME — Gemfile-root basename (default: SERVICE)
#   QUALITY_RUBOCOP_DOCKER_PARENT   — parent dir of that root (default: app)
#   QUALITY_RUBOCOP_DOCKER_COMPOSE  — compose file under grandparent
#                                     (default: compose/app.yaml)
#   QUALITY_LOCAL        — optional extra Ruby file after public modules
#                          (default: ~/.cursor/hooks/quality_local.rb if present)
#
# Implementation lives in hooks/quality/*.rb (Quality::* modules).

require 'json'
require 'fileutils'

require_relative 'quality/config'
require_relative 'quality/support'
require_relative 'quality/turn_files'
require_relative 'quality/formal'
require_relative 'quality/stages'

local = ENV['QUALITY_LOCAL'].to_s
local = File.join(ENV['HOME'].to_s, '.cursor/hooks/quality_local.rb') if local.empty?
require local if File.file?(local)

# Cursor stop-hook entry: wires Quality::* mixins and runs the pipeline.
class QualityHook
  include Quality::Support
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
    if @input['status']
      stop_pipeline
    else
      empty
    end
  rescue StandardError => e
    STDERR.puts "[quality] #{e.class}: #{e.message}\n#{e.backtrace.first(6).join("\n")}"
    empty
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
    extras = []
    home = ENV['HOME'].to_s
    extras << "#{home}/.rbenv/shims" if File.directory?("#{home}/.rbenv/shims")
    extras << "#{home}/.rbenv/bin" if File.directory?("#{home}/.rbenv/bin")
    extras << '/opt/homebrew/bin' if File.directory?('/opt/homebrew/bin')
    extras << "#{home}/.local/bin" if File.directory?("#{home}/.local/bin")
    ENV['PATH'] = (extras + [ENV['PATH'] || '/usr/bin:/bin']).join(':')
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
    # the followup with `{}` (verify / rubocop / etc. never reached the agent).
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
