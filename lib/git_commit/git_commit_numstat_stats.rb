# frozen_string_literal: true

# Collects and combines staged and unstaged git numstat output.
module GitCommitNumstatStats
  def get_file_stats(files, all_stats = nil)
    return {} unless files.any?

    batch = all_stats || fetch_all_numstat_stats
    files.to_h do |file|
      path = file.to_s.strip
      [file, lookup_stat(batch, path) || get_single_file_stats(path) || ""]
    end
  end

  def lookup_stat(batch, path)
    batch[path] || batch[path.delete_prefix("./")] || batch["./#{path}"]
  end

  def fetch_all_numstat_stats
    merge_stat_hashes(
      parse_numstat_to_hash(`git diff --cached --numstat 2>/dev/null`),
      parse_numstat_to_hash(`git diff --numstat 2>/dev/null`)
    )
  end

  def parse_numstat_to_hash(out)
    return {} unless out && !out.strip.empty?

    out.each_line.filter_map { |line| parse_numstat_line_to_stat(line) }.to_h do |stat|
      [stat[:path], stat[:stat]]
    end
  end

  def parse_numstat_line_to_stat(line)
    add_str, del_str, path = line.strip.split("\t", 3)
    return nil if add_str.nil? || del_str.nil? || path.nil? || path.empty?
    return nil if add_str == "-" || del_str == "-"

    add = add_str.to_i
    delete = del_str.to_i
    return nil unless (add + delete).positive?

    {path: path.strip, stat: "#{add}+#{delete}-"}
  end

  def merge_stat_hashes(cached, unstaged)
    unstaged.each_with_object(cached.dup) do |(path, stat), result|
      add, delete = parse_stat_string(stat)
      next unless add && delete

      result[path] = "#{add.to_i + sum_from_stat(result[path], 0)}+" \
        "#{delete.to_i + sum_from_stat(result[path], 1)}-"
    end
  end

  def sum_from_stat(stat_str, index)
    captures = parse_stat_string(stat_str)
    captures && captures[index] ? captures[index].to_i : 0
  end

  def parse_stat_string(stat)
    stat&.match(/(\d+)\+(\d+)-/)&.captures
  end
end
