# frozen_string_literal: true

# Assessment, warning fixes, and unified-diff helpers for multi-stage refactoring.
module RefactorAssessment
  private

  def fix_warnings_if_needed(client, _original_file_codes, current_file_codes, assessment, user_instruction)
    fixed_files = attempt_to_fix_warnings(client, current_file_codes, assessment['warnings'], user_instruction)
    return current_file_codes if fixed_files.empty?

    fixed_files.each { |path, code| current_file_codes[path] = code }
    current_file_codes
  end

  def satisfied?(assessment)
    assessment['satisfied'] && !critical_warnings?(assessment['warnings'])
  end

  def critical_warnings?(warnings)
    return false if warnings.nil? || warnings.empty?

    warnings.any? { |w| w['critical'] == true || (w['probability'] || 0) > 0.8 }
  end

  def attempt_to_fix_warnings(client, current_file_codes, warnings, user_instruction)
    puts "Attempting to fix warnings with #{client.instance_variable_get(:@model)}...".blue

    ResponseParser.parse_files_from_response(
      client.ask(
        refactor_messages(current_file_codes, warning_fix_instruction(warnings, user_instruction)),
        title: 'Fixing warnings'.cyan
      ),
      current_file_codes.keys,
      exit_on_error: false
    )
  end

  def warning_fix_instruction(warnings, user_instruction)
    text = "Fix these issues from the previous refactoring step:\n#{warnings.map do |w|
      critical = w['critical'] ? ' [CRITICAL]' : ''
      "- #{w['message']} (probability: #{w['probability']})#{critical}"
    end.join("\n")}"
    user_instruction ? "#{text}\n\nOriginal instruction: #{user_instruction}" : text
  end

  def last_stage?(index)
    index == @clients.size - 1
  end

  def perform_assessment(original_file_codes, current_file_codes, user_instruction, client: nil)
    client ||= @clients.first
    puts "--- Assessing if instruction is fulfilled (#{client.instance_variable_get(:@model)}) ---".blue

    result = ResponseParser.extract_json(
      client.ask(
        assessment_messages(build_assessment_prompt(original_file_codes, current_file_codes, user_instruction)),
        json: true,
        title: 'Assessing refactoring'.cyan
      )
    )
    display_assessment_result(result)
    result
  rescue StandardError => e
    warn "Warning: Self-assessment failed: #{e.message}"
    {'satisfied' => false, 'reason' => "Assessment failed: #{e.message}", 'warnings' => []}
  end

  def assessment_messages(prompt)
    [
      {role: 'system', content: assessment_system_content},
      {role: 'user', content: prompt}
    ]
  end

  def assessment_system_content
    'You are an expert code reviewer. Assess if the user\'s refactoring instruction ' \
      'has been fully fulfilled. Respond ONLY with a JSON object: ' \
      '{"satisfied": true/false, "reason": "brief explanation", "warnings": ' \
      '[{"message": "...", "probability": 0..1, "critical": true/false}]}'
  end

  def display_assessment_result(result)
    color = result['satisfied'] ? :green : :yellow
    puts "Assessment: #{result['reason']}".colorize(color)
    display_assessment_warnings(result['warnings'])
  end

  def display_assessment_warnings(warnings)
    return if warnings.nil? || warnings.empty?

    puts 'Warnings:'.yellow
    warnings.each { |warning| puts assessment_warning_line(warning) }
  end

  def assessment_warning_line(warning)
    critical = warning['critical'] ? ' [CRITICAL]'.red : ''
    "  - #{warning['message']} (probability: #{warning['probability'] || 0})#{critical}".yellow
  end

  def build_assessment_prompt(original_file_codes, current_file_codes, user_instruction)
    instruction = user_instruction || load_refactor_md
    prompt = "User Instruction: #{instruction}\n\n"
    prompt += 'Review the following changes (in unified diff format) and determine if they fulfill the instruction:' \
              "\n\n"
    current_file_codes.each do |path, current_code|
      original_code = original_file_codes[path]
      next if original_code == current_code

      prompt += "#{generate_diff(path, original_code, current_code)}\n"
    end
    prompt
  end

  def generate_diff(path, original, current)
    Tempfile.create(['original', File.extname(path)]) do |f1|
      write_tempfile(f1, original)
      Tempfile.create(['current', File.extname(path)]) do |f2|
        write_tempfile(f2, current)
        diff = `diff -u #{Shellwords.shellescape(f1.path)} #{Shellwords.shellescape(f2.path)}`
        diff.sub(/^--- .*\n\+\+\+ .*\n/, "--- a/#{path}\n+++ b/#{path}\n")
      end
    end
  rescue StandardError => e
    warn "Warning: Diff generation failed for #{path}: #{e.message}"
    "--- a/#{path}\n+++ b/#{path}\n@@ -0,0 +0,0 @@\n(Diff failed, original and refactored versions differ)\n"
  end

  def write_tempfile(file, content)
    file.binmode
    file.write(content)
    file.close
  end
end
