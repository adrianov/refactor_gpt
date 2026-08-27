# frozen_string_literal: true

require 'fileutils'
require 'digest'

module Quality
  # Pipeline sequencing plus review/document reports and git_commit_gpt.
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
        return empty unless completed?

        files, chain, stage, saved = boot_cycle
        return empty_files_path if !chain && files.empty?

        run_stages(advance_stage(stage, files, chain), files, saved, chain)
      end
    end
    def boot_cycle
      cleanup_state
      claim_active(workspace_git_root)
      files = this_turn_files
      chain = followup_chain?
      stage, saved = load_stage
      log_action('boot', chain: chain, stage: stage || 'formal', files: files.size)
      chain ? [files, chain, stage, saved] : (unset_review_flags; [files, chain, 'formal', []])
    end
    def empty_files_path
      log_action('stage', name: 'commit-empty-files')

      (msg = timed('commit-empty-files') { run_commit }) ? followup(msg) : finish_empty
    end
    def advance_stage(stage, files, chain)
      return 'formal' if stage.nil? || stage.empty? || !chain

      case stage
      when 'commit_fix' then files.empty? ? 'commit' : 'formal'
      else files.empty? || md_only?(files) ? STALLED_NEXT.fetch(stage, 'commit') : 'formal'
      end
    end
    def run_stages(stage, files, saved, chain)
      %w[formal review document].each do |name|
        next unless stage == name

        log_action('stage', name: name, files: files.size, list: files.first(3).join(','), saved: saved.size, chain: chain)
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
        unset_review_flags
        save_stage('commit_fix', files)
        return followup(msg)
      end
      clear_stage
      finish_empty
    end
    def followup_chain?
      return true if @input['loop_count'].to_i != 0

      text = last_user_text
      return false if text.empty?

      pending = File.file?(pending_file) ? File.readlines(pending_file)[0].to_s[0, 120] : ''
      (!pending.empty? && text.include?(pending)) || text.match?(FOLLOWUP_RE)
    end
    def review_report(files)
      files = Array(files).select { |f| File.file?(f) || f =~ %r{(^|/)db/schema\.rb$}i }
      parts = [verify_part(files), scatter_part(files), (SCHEMA_MSG if schema_edited?)].compact
      parts.empty? ? nil : parts.join("\n\n")
    end
    def verify_part(files)
      return nil if review_flag?('verify') || md_only?(files) || files.empty? || git_clean_files?(files)

      set_review_flag('verify')
      VERIFY
    end
    def scatter_part(files)
      return nil if review_flag?('scatter') || (n = files.count { |f| main_module?(f) }) < SCATTER

      set_review_flag('scatter')
      "#{n} modules were edited during this feature implementation. " \
        'Consider consolidating if that would make the intent clearer.'
    end
    def document_report(files)
      md = Array(files).select { |f| changed_md_file?(f) }
      mark_md_reviewed(md)
      md.empty? ? nil : "#{MD_MSG}\n#{md.map { |f| "- #{f}" }.join("\n")}"
    end
    def changed_md_file?(abs)
      return false if abs.to_s.empty? || abs !~ /\.md$/i || !File.file?(abs)

      abs = File.realpath(abs) rescue abs.to_s
      return false if md_reviewed?(abs)

      root = git_root(File.dirname(abs))
      return tracked_new_md?(root, abs) if root

      true
    end
    def tracked_new_md?(root, abs)
      root = File.realpath(root) rescue root
      (rel = rel_to(root, abs)) && capture('git', '-C', root, 'cat-file', '-e', "HEAD:#{rel}")[2] != 0
    end
    # Wording pass fires exactly once per file path: the digest recorded after a
    # fire marks the file as reviewed, so later edits never re-arm the gate. The
    # agent applies the suggestion right away, so a repeat would only echo the
    # same message over an already-improved text.
    def md_reviewed?(abs)
      md_digests.key?(abs)
    end
    def mark_md_reviewed(files)
      return if files.empty?

      store = md_digests
      files.each do |abs|
        real = File.realpath(abs) rescue abs.to_s
        store[real] = Digest::SHA256.file(real).hexdigest
      end
      File.write(Quality::MD_REVIEW_DIGESTS, JSON.generate(store))
    rescue StandardError
      nil
    end
    def md_digests
      JSON.parse(File.read(Quality::MD_REVIEW_DIGESTS))
    rescue StandardError
      {}
    end
    def git_clean_files?(files)
      files.each do |abs|
        next if abs.to_s.empty? || !(root = git_root(File.dirname(abs)))
        next unless (rel = rel_to(root, abs))

        return false unless capture('git', '-C', root, 'status', '--porcelain', '--', rel)[0].to_s.empty?
      end
      # Files outside any repo (or all-clean repo files) leave nothing pending.
      true
    end
    def schema_edited?
      # Own repos commit schema.rb as generated; the minimal-change note is for other remotes.
      return false if owned_workspace?
      return true if schema_tool_edit?

      migration_dirtied_schema?
    end
    def migration_dirtied_schema?
      return false unless this_turn_shell_commands.any? { |c| c =~ SCHEMA_SHELL_RE }

      root = @roots[0]
      return false if root.nil? || !File.directory?(root) || !git_root(root)

      !capture('git', '-C', root, 'status', '--porcelain', '--', 'db/schema.rb')[0].to_s.empty?
    end
    def schema_tool_edit?
      this_turn_tools.any? { |t| t['name'] != 'Shell' && tool_paths(t).any? { |p| p =~ %r{(^|/)db/schema\.rb$}i } }
    end
  end
end
