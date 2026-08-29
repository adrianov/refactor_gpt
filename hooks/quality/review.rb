# frozen_string_literal: true

require 'digest'
require 'fileutils'

module Quality
  # Review and document follow-up text: verify, scatter, schema, new markdown.
  module Review
    # Survives formal/commit flag resets so an unchanged module count does not
    # re-loop the verify+scatter follow-up; cleared on a fresh user turn.
    def scatter_count_file; File.join(STATE, "stop-scatter-n-#{@session_key}"); end
    def last_scatter_count
      return nil unless File.file?(scatter_count_file)

      File.read(scatter_count_file).to_i
    rescue StandardError
      nil
    end
    def save_scatter_count(n)
      FileUtils.mkdir_p(STATE)
      File.write(scatter_count_file, "#{n}\n")
    end
    def clear_scatter_count
      File.delete(scatter_count_file) if File.file?(scatter_count_file)
    rescue StandardError
      nil
    end
    def clear_stage
      super
      clear_scatter_count
    end
    def review_report(files)
      files = Array(files).select { |f| File.file?(f) || f =~ %r{(^|/)db/schema\.rb$}i }
      parts = [verify_part(files), scatter_part(files), (SCHEMA_MSG if schema_edited?)].compact
      parts.empty? ? nil : parts.join("\n\n")
    end
    def verify_part(files)
      return nil if review_flag?('verify') || md_only?(files) || files.empty? || git_clean_files?(files)
      return nil if stable_scatter?(files)

      set_review_flag('verify')
      VERIFY
    end
    def scatter_part(files)
      n = module_edit_count(files)
      return nil if review_flag?('scatter') || n < SCATTER || n == last_scatter_count

      set_review_flag('scatter')
      save_scatter_count(n)
      "#{n} modules were edited during this feature implementation. " \
        'Consider consolidating if that would make the intent clearer.'
    end
    def module_edit_count(files)
      files.count { |f| main_module?(f) }
    end
    # Same scatter count as last emission: skip verify+scatter after formal/commit
    # flag resets so the agent is not looped on an unchanged footprint.
    def stable_scatter?(files)
      n = module_edit_count(files)
      n >= SCATTER && n == last_scatter_count
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
      # Own repos commit schema.rb as generated; the minimal-change note is
      # for other remotes. Git status covers direct edits and migration
      # regenerations alike.
      return false if owned_workspace?

      changed_files.any? { |p| p =~ %r{(^|/)db/schema\.rb$}i }
    end
  end
end
