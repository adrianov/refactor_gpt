# frozen_string_literal: true

require "shellwords"
require "colorize"

# One git_explain_gpt run: scoped status/diff, Markdown explanation, optional follow-up Q&A.
class GitExplainSession
  def initialize(args)
    @debug, @paths = parse(args)
  end

  def run
    @paths = GitStatusPaths.expand_partners(@paths)
    spec = GitPathspec.args(@paths)
    status = git_output("status", "--porcelain", "--branch", *spec)
    return no_changes if clean?(status)

    intend_untracked(spec)
    diff = git_output("diff", "-U500", *spec)
    explanation = GitExplainer.new(debug: @debug).explain_changes(
      status, diff, recent_commits, RecentShellCommands.last_few(5)
    )
    show(explanation)
    follow_up(explanation) if $stdin.tty?
  end

  private

  def parse(args)
    debug = args.include?("--debug")
    rest = args.reject { |arg| arg == "--debug" }
    _hint, paths = CliPaths.partition(rest)
    [debug, CliPaths.select_supported(paths, DiffProcessor::CODE_EXTENSIONS)]
  end

  def git_output(*argv)
    cmd = ["git", *argv].shelljoin
    output = Utility.utf8_safe(`#{cmd}`)
    return output if $?.success?

    warn "Failed to capture diff for analysis".red if argv.first == "diff"
    warn "Command failed: #{cmd}".red unless argv.first == "diff"
    exit 1
  end

  def clean?(status)
    status.lines.count { |line| !line.start_with?("##") }.zero?
  end

  def no_changes
    puts "No changes to explain.".yellow
  end

  def intend_untracked(spec)
    listed = `git ls-files --others --exclude-standard --directory #{spec.shelljoin}`.split("\n")
    files = listed.reject { |file| GitCommitExecutor.ephemeral_path?(file) }
    return if files.empty?

    system(["git", "add", "-N", *files].map { |p| Shellwords.escape(p) }.join(" ") + " 2>/dev/null")
  end

  def recent_commits
    `git log -15 --pretty=%s 2>/dev/null`.strip
  end

  def show(content)
    return puts content unless Utility.glow_available?

    Utility.display_with_glow(
      Utility.format_answer(content),
      Utility.calculate_width(Utility.extract_urls(content))
    )
  end

  def follow_up(explanation)
    puts "\n💬 Ask follow-up questions about the changes (Ctrl+D to exit):"
    puts "   • Type your questions about specific files, implementation details, or suggestions"
    puts "   • Press Enter twice to submit your question\n"
    explainer = GitExplainer.new(debug: @debug)
    messages = [
      {role: "system", content: followup_instruction},
      {role: "assistant", content: explanation}
    ]
    ask_until_eof(explainer, messages)
  end

  def ask_until_eof(explainer, messages)
    loop do
      question = PromptReader.read_multiline
      break unless question

      messages << {role: "user", content: question}
      answer = explainer.ask(messages)
      messages << {role: "assistant", content: answer}
      show(answer)
      puts "\n"
    end
  end

  def followup_instruction
    <<~HEREDOC
      You are helping a developer understand git changes through a Q&A session. The user has already received a comprehensive initial analysis with detailed structure. Now they want focused follow-up answers.

      CRITICAL: For follow-up questions, provide SHORT, FOCUSED responses. The big detailed structure was for the initial analysis only.

      Your role for follow-ups:
      - Answer specific questions directly and concisely
      - Clarify points from the initial analysis
      - Provide targeted code examples when needed
      - Suggest specific improvements for particular concerns

      Response format for follow-ups:
      - 1-3 paragraphs maximum for complex topics
      - 1-2 sentences for simple questions
      - Use bullet points only when listing multiple distinct items
      - Avoid repeating the comprehensive structure from initial analysis
      - Focus only on what the user specifically asked

      Examples:
      Q: "Why was this method extracted?"
      A: "The method was extracted to reduce complexity and improve testability. It now has a single responsibility for processing user input, making the code more maintainable."

      Q: "What about error handling?"
      A: "The extracted method includes input validation and raises ArgumentError for invalid data. Error cases are handled at the boundary rather than scattered throughout the original method."

      Guidelines:
      - Be direct and to the point
      - Reference specific files/lines when relevant
      - Provide minimal but sufficient code examples
      - Focus on the specific question asked
    HEREDOC
  end
end
