# frozen_string_literal: true

# Runs a loop reading JSON job lines from stdin; for each job runs one agent step and writes
# {"done":true,"code":N} to stdout. Enables "reuse agent process": one long-lived Ruby process
# driven by an external caller that sends multiple jobs (implement, verify, refactor, ask).

class StdinCommandsRunner
  COMMANDS = %w[agent implement verification refactor ask].freeze

  def initialize(stdin: $stdin, stdout: $stdout, stderr: $stderr)
    @stdin = stdin
    @stdout = stdout
    @stderr = stderr
    @display = Display.new(io: stderr)
    @session_tracker = nil
    @agent_executor = AgentExecutor.new(@display, session_tracker: @session_tracker, show_full_prompt: false)
    @verification_handler = VerificationHandler.new(@display, @agent_executor)
  end

  def run
    @stdin.each_line do |line|
      line = line.to_s.strip
      next if line.empty?

      code = process_job(line)
      @stdout.puts({ done: true, code: code }.to_json)
      @stdout.flush
    end
  end

  private

  def process_job(line)
    job = normalized_job_hash(line)
    return -1 unless job
    return -1 if validate_job(job)

    request = job_request(job)
    return -1 if request.to_s.strip.empty?

    run_job_with_params(job, request)
  rescue StandardError => e
    @stderr.puts "stdin-commands: #{e.message}"
    -1
  end

  def normalized_job_hash(line)
    job = parse_job(line)
    job.is_a?(Hash) ? job.transform_keys { |k| k.to_s } : nil
  end

  def run_job_with_params(job, request)
    command = normalize_command(job['command'])
    model = (job['model'] || 'auto').to_s.strip
    model = 'auto' if model.empty?
    run_job_in_dir(
      job['working_dir'], command, model, request,
      job['previous_output'], job['log_path']
    )
  end

  def validate_job(job)
    working_dir = job['working_dir']
    unless working_dir && Dir.exist?(working_dir)
      @stderr.puts "stdin-commands: invalid or missing working_dir"
      return :invalid
    end
    command = normalize_command(job['command'])
    unless COMMANDS.include?(command)
      @stderr.puts "stdin-commands: unknown command #{command.inspect}"
      return :invalid
    end
    nil
  end

  def normalize_command(cmd)
    c = (cmd || 'agent').to_s.strip.downcase
    c == 'implement' ? 'agent' : c
  end

  def run_job_in_dir(working_dir, command, model, request, previous_output, log_path)
    orig_cwd = Dir.pwd
    Dir.chdir(working_dir)
    run_one_job(command, model, request, previous_output, log_path)
  ensure
    Dir.chdir(orig_cwd)
  end

  def parse_job(line)
    Oj.load(line, mode: :strict)
  rescue Oj::ParseError
    nil
  end

  def job_request(job)
    req = job['request']
    return req if req && !req.to_s.strip.empty?

    path = job['request_file']
    return nil unless path && File.readable?(path)

    File.read(path).to_s.strip
  end

  def run_one_job(command, model, request, previous_output, log_path)
    prompt = build_prompt(command, request, previous_output)
    success, output, _reason = @agent_executor.run(
      model, prompt,
      verification_mode: (command == 'verification'),
      new_session: %w[agent refactor].include?(command),
      fix_stage: false,
      current_request: request
    )
    File.write(log_path, output.to_s) if log_path && output
    success ? 0 : 1
  end

  def build_prompt(command, request, previous_output)
    case command
    when 'agent'
      request
    when 'verification'
      @verification_handler.build_verification_prompt(request, previous_output)
    when 'refactor'
      @verification_handler.build_refactor_prompt(request)
    when 'ask'
      request
    else
      request
    end
  end
end
