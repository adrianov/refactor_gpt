# frozen_string_literal: true

require "colorize"
require "open3"

# Rebases onto the default branch when it has moved and the replay is clean.
class GitCommitRebase
  def self.run
    new.run
  end

  def self.push_command(rebased)
    return %w[git push] unless rebased
    return %w[git push --force-with-lease] if upstream?

    remote = remote_name
    return ["git", "push", "-u", remote, "HEAD"] if remote

    %w[git push]
  end

  def self.remote_name
    out, status = Open3.capture2("git", "remote")
    return unless status.success?

    names = out.split
    names.include?("origin") ? "origin" : names.first
  end

  def self.upstream?
    _, status = Open3.capture2e("git", "rev-parse", "--verify", "--quiet", "@{upstream}")
    status.success?
  end

  def run
    fetch_remote
    ref = moved_base
    return if ref.nil?

    rebase(ref)
  end

  private

  def fetch_remote
    remote = self.class.remote_name
    return unless remote

    puts "Running: git fetch #{remote}".green
    system("git", "fetch", "--quiet", remote)
  end

  def moved_base
    return if base_branch?

    BranchPoint::BASE_REFS.each do |ref|
      tip = commit_sha(ref)
      next unless tip

      point = BranchPoint.merge_base(nil, ref)
      next unless point

      return point == tip ? nil : ref
    end
    nil
  end

  def base_branch?
    short = current_branch
    short.nil? || short == "HEAD" || base_names.include?(short)
  end

  def current_branch
    out, status = Open3.capture2("git", "rev-parse", "--abbrev-ref", "HEAD")
    status.success? ? out.strip : nil
  end

  def base_names
    names = %w[master main]
    label = BranchPoint.ref_label(nil, "origin/HEAD")
    names << label.delete_prefix("origin/") if label.to_s.start_with?("origin/")
    names
  end

  def commit_sha(ref)
    out, status = Open3.capture2("git", "rev-parse", "--verify", "--quiet", "#{ref}^{commit}")
    return unless status.success?

    sha = out.strip
    sha unless sha.empty?
  end

  def rebase(ref)
    puts "Running: git rebase #{ref}".green
    output, ok = rebase_output(ref)
    return ref if ok

    system("git", "rebase", "--abort", out: File::NULL, err: File::NULL)
    return skip_rebase(ref) unless rebase_in_progress?

    print output
    warn "Rebase onto #{ref} failed and could not be aborted.".red
    exit 1
  end

  def rebase_output(ref)
    output, status = Open3.capture2e("git", "rebase", ref)
    print output if status.success?
    [output, status.success?]
  end

  def skip_rebase(ref)
    puts "Cannot rebase onto #{ref} cleanly; pushing without rebase.".yellow
    nil
  end

  def rebase_in_progress?
    %w[rebase-merge rebase-apply].any? { rebase_dir?(it) }
  end

  def rebase_dir?(name)
    out, status = Open3.capture2("git", "rev-parse", "--git-path", name)
    status.success? && File.directory?(out.strip)
  end
end
