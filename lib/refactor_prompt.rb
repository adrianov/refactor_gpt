# frozen_string_literal: true

# System and user prompt text for refactor_gpt.rb. Kept out of the runner so the
# wording can be edited without touching control flow.
module RefactorPrompt
  module_function

  def build_system_instruction
    [refactor_output_format_instruction, refactor_behavior_instruction].join("\n\n")
  end

  def refactor_output_format_instruction
    (<<~HEREDOC
      Return refactored files using this format:
      <full_file_contents_to_replace filename="[REPLACE_WITH_ACTUAL_FILE_PATH]">complete file content</full_file_contents_to_replace>

      The <full_file_contents_to_replace> tags and the complete file content between them must be
      output on separate lines. The file content between the opening and
      closing tags can span multiple lines and must include every line of the
      file exactly as it should appear.

      Files provided as context use this format in the prompt and must NOT be
      returned:
      <content filename="path/to/file.rb">
      complete file content
      </content>

      Content between <full_file_contents_to_replace> and </full_file_contents_to_replace> tags MUST be the complete file
      content from the first line to the last line. Never abbreviate, cut, or
      use placeholders like "...". Always include all lines of the file.

      Content between <content> and </content> tags in the prompt is provided as
      reference only. Never return files that were marked with <content>. Only
      return files you actually modify.

      ALWAYS use <full_file_contents_to_replace> tags for ALL returned files, including single-file responses.
      Never return raw text without tags. This is required for both single-file and multi-file responses.

      CRITICAL: DO NOT create new files. Only refactor the files provided in the prompt.
      If you think a new file is needed, refactor the existing code instead.
    HEREDOC
    ).strip
  end

  # Instruction for how to refactor (behavior only). Edit this when improving wording for humans/LLMs.
  def refactor_behavior_instruction
    (<<~HEREDOC
      Apply changes that make code easier to edit and understand for both humans and LLMs:
      improve structure and remove duplication; use clear, literal names; keep methods and
      blocks small and focused; prefer explicit logic over clever or implicit code; keep
      formatting and structure consistent so readers and tools can parse reliably.
      Preserve all existing comments unless they describe code you change or you implement
      a TODO. When making bug fixes or requested changes, keep the diff minimal. Never
      suggest purely stylistic changes (quote style, alternative method names). Only make
      necessary structural improvements.
    HEREDOC
    ).strip
  end

  def build_refactor_prompt(file_codes, user_instruction)
    <<~HEREDOC
      #{user_instruction || load_refactor_md}

      Files are provided below using <content> tags. You may use some files only as
      context and leave them unchanged. Only return files you actually modify.

      #{file_codes.map { |path, code| "<content filename=\"#{path}\">\n#{code}\n</content>" }.join("\n\n")}
    HEREDOC
  end
end
