# frozen_string_literal: true

module Quality
  # Pipeline sequencing: formal → review → document → commit. One follow-up
  # per stop; review/document message bodies live in Quality::Review.
  module Stages
    # Next stage when a chain turn produced nothing actionable; anything that
    # did produce edits always restarts formal.
    STALLED_NEXT = {
      'formal' => 'review', 'review' => 'document', 'document' => 'commit'
    }.freeze
    # :stalled unwinds the whole pipeline when a repeat followup is suppressed;
    # returning nil from a stage there would cascade into later stages instead.
    def stop_pipeline
      catch(:stalled) do
        root = workspace_git_root
        log_action('start', status: @input['status'].to_s, dir: @roots[0].to_s, git: root ? 'yes' : 'no')
        return empty unless pipeline_ready?(root)

        run_pipeline
      end
    end

    def pipeline_ready?(root)
      return false unless completed?
      return false unless cursor_write_gate?

      # Workspace cwd keys omp session dirs; fall back to git top when unset.
      gate = @roots[0].to_s
      sole_session?(gate.empty? ? root : gate)
    end
    def run_pipeline
      files, chain, stage, saved = boot_cycle
      return empty_files_path if !chain && files.empty?

      run_stages(advance_stage(stage, files, chain), files, saved, chain)
    end
    def boot_cycle
      cleanup_state
      files = changed_files
      chain = followup_chain?
      stage, saved = load_stage
      log_action('boot', chain: chain, stage: stage || 'formal', files: files.size)
      return [files, chain, stage, saved] if chain

      unset_review_flags
      clear_scatter_count
      [files, chain, 'formal', []]
    end
    def empty_files_path
      log_action('stage', name: 'commit-empty-files')

      (msg = timed('commit-empty-files') { run_commit }) ? followup(msg) : finish_empty
    end
    def advance_stage(stage, files, chain)
      return 'formal' if stage.nil? || stage.empty? || !chain

      case stage
      # After a git_commit_gpt guideline warning fix: re-run formal when files
      # changed (abcop), then review/document. VERIFY/scatter/schema flags stay
      # set from the earlier pass, so an empty review falls through to commit.
      when 'commit_fix' then files.empty? || md_only?(files) ? 'commit' : 'formal'
      else files.empty? || md_only?(files) ? STALLED_NEXT.fetch(stage, 'commit') : 'formal'
      end
    end
    def run_stages(stage, files, saved, chain)
      %w[formal review document].each do |name|
        next unless stage == name

        log_action('stage', name: name, files: files.size, list: files.first(3).join(','), saved: saved.size,
                   chain: chain)
        msg = timed(name) { send(:"#{name}_stage", files, saved, *(name == 'formal' ? [chain] : [])) }
        return msg if msg

        stage = { 'formal' => 'review', 'review' => 'document', 'document' => 'commit' }[name]
      end
      commit_followup(files) if stage == 'commit'
    end
    def review_stage(files, saved)
      rf = files.empty? ? saved : files
      (msg = review_report(rf)) && (save_stage('review', rf); followup(msg))
    end
    def document_stage(files, saved)
      df = (files + saved).uniq
      (msg = document_report(df)) && (save_stage('document', df); followup(msg))
    end
    def commit_followup(files)
      log_action('stage', name: 'commit', files: files.size)
      if (msg = timed('commit') { run_commit })
        # Keep VERIFY/scatter/schema flags. Clearing them on a guideline warning
        # made the next stop re-emit review follow-ups instead of reaching
        # commit once review returned nothing.
        save_stage('commit_fix', files)
        return followup(msg)
      end
      clear_stage
      finish_empty
    end
    def followup_chain?
      return true if @input['loop_count'].to_i != 0

      # Scan recent user texts, not just the last one: a mid-turn user interjection
      # pushes the delivered followup out of last position, which used to reset the
      # chain (unset review flags) and re-emit the same advisory every turn.
      pending = File.file?(pending_file) ? File.readlines(pending_file)[0].to_s[0, 120] : ''
      recent_user_texts.any? do |text|
        (!pending.empty? && text.include?(pending)) || text.match?(FOLLOWUP_RE)
      end
    end
  end
end
