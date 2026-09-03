# frozen_string_literal: true

# Parses git output and ranks changed files for diff assembly.
module DiffProcessorFiles
  private

  def code_file?(file_path)
    CODE_EXTENSIONS.include?(File.extname(file_path).to_s.downcase)
  end

  def parse_file_diffs(diff_output)
    return {} if diff_output.empty?

    file_diffs = {}
    current_file = nil
    current_diff = []
    diff_output.lines.each do |line|
      if line.start_with?("diff --git")
        file_diffs[current_file] = current_diff.join if current_file
        current_file = extract_file_path_from_diff_header(line)
        current_diff = [line]
      elsif current_file
        current_diff << line
      end
    end
    file_diffs[current_file] = current_diff.join if current_file
    file_diffs
  end

  def extract_file_path_from_diff_header(line)
    return nil unless line.start_with?("diff --git ")

    rest = line.sub("diff --git ", "")
    b_index = rest.rindex(" b/")
    b_index && rest[(b_index + 3)..]
  end

  def parse_file_statuses(status_output)
    status_output.lines.each_with_object({}) do |line, statuses|
      file_path = extract_status_file_path(line)
      statuses[file_path] = line[0..1] if file_path
    end
  end

  def extract_status_file_path(line)
    return nil if line.nil? || line.to_s.strip.empty? || line.start_with?("##")

    file_path = line[3..]&.to_s&.strip
    return nil if file_path.nil? || file_path.empty?

    file_path.include?(" -> ") ? file_path.split(" -> ").last : file_path
  end

  def sort_files_by_importance(file_diffs, file_statuses)
    file_diffs.keys.sort_by do |file_path|
      status = file_statuses[file_path] || "??"
      calculate_file_score(file_path, status, file_diffs[file_path].bytesize)
    end.map { |file_path| [file_path, file_diffs[file_path]] }
  end

  def calculate_file_score(file_path, status, diff_size)
    [
      status_priority(status),
      file_path.count("/"),
      extension_priority(File.extname(file_path).downcase),
      File.basename(file_path).length,
      diff_size / 1000
    ]
  end

  def status_priority(status)
    case status
    when /M/ then 1
    when /A/, "??" then 2
    when /D/ then 3
    else 4
    end
  end

  def extension_priority(ext)
    return 0 if CODE_EXTENSIONS.include?(ext)

    case ext
    when ".lock", ".sum", ".mod" then 5
    when ".log", ".tmp", ".bak" then 9
    else 3
    end
  end
end
