# frozen_string_literal: true

# Shared system-instruction text for AskGptClient and AskGeminiClient.
# System text stays byte-stable for prompt caching; clock goes on the last user turn.
module AskClientInstructions
  def build_style_instruction(style)
    return "Answer in a Lovecraftian, eldritch horror tone" if style == :eldritch

    <<~HEREDOC
      - Answer in clear, concise terms, prioritizing Ruby concepts and tooling.
      - Prefer idiomatic Ruby style in all code examples.
      - Use Markdown formatting (headings, lists, fenced code blocks) where helpful.
      - Default code fences to Ruby unless another language is clearly required.
      - Always respond using Markdown formatting, even for very short answers.
    HEREDOC
  end

  def build_brevity_instruction
    <<~HEREDOC
      Answer in 1–2 short, direct phrases; be as brief as possible while still being correct and useful.
      Avoid lists, headings, or multi-sentence paragraphs unless absolutely necessary.
      If a one-word answer would be fully correct and sufficient, answer with that one word.
    HEREDOC
  end

  def base_instruction(style_instr)
    <<~HEREDOC
      You are a Ruby-focused assistant helping a Ruby programmer.

      Style and format:
      #{style_instr}

      Answer length:
      - Be succinct and avoid unnecessary theory.
      - Include just enough detail and examples to make solution directly usable.
      - If user asks a short, direct question and does not explicitly request detail,
        respond with a short, direct answer (1–3 short sentences or bullet points) by default.
      - If the user's question can be fully answered with a single word (e.g., "yes", "no", a name, a number),
        respond with exactly that one word unless they explicitly ask for explanation.

      Code and explanations:
      - When showing code, make it copy-pastable and minimal.
      - Briefly explain non-obvious parts of the code.
      - If there are multiple reasonable approaches, mention the most common one first.

      Formatting restrictions:
      - Do not use Markdown tables, as they cannot be parsed properly.

      Translations:
      - Provide translations to Russian, English, French, German, Spanish, and Italian
      - Follow user-specified language pairs when provided
      - For short phrases: include translation, phonetics, and brief etymology when relevant

      Ruby gems:
      - When you recommend Ruby gems, always include a GitHub repository URL for each gem
        you mention, in form: `gem_name – https://github.com/owner/repo`
        whenever such a public repository is known or can be reasonably inferred.
    HEREDOC
  end

  def build_system_instruction(style, brevity)
    style_instr = build_style_instruction(style)
    style_instr += build_brevity_instruction if brevity == :short

    result = base_instruction(style_instr).to_s.strip
    system_info = SystemInfo.to_s
    result += "\n\nUser environment:\n#{system_info}" unless system_info.empty?
    result
  end

  def build_system_message(style, brevity)
    {role: 'system', content: build_system_instruction(style, brevity)}
  end

  def chat(question, style: nil, brevity: nil)
    ask([build_system_message(style, brevity), {role: 'user', content: question}])
  end

  def ask(messages, json: false, title: nil)
    @client.ask(prepare_ask_messages(messages), json: json, title: title)
  end

  def prepare_ask_messages(messages)
    with_dated_last_user(promote_system_prefix(messages))
  end

  def with_dated_last_user(messages)
    date_info = SystemInfo.date_info
    return messages if date_info.empty?

    idx = messages.rindex { |message| role_of(message) == 'user' }
    return messages unless idx

    dated_user_at(messages, idx, date_info)
  end

  def promote_system_prefix(messages)
    return messages if messages.any? { |message| role_of(message) == 'system' }

    first = messages[0]
    return messages unless messages.size >= 2 && first && role_of(first) == 'user'

    [{role: 'system', content: first[:content] || first['content']}] + messages[1..]
  end

  def dated_user_at(messages, idx, date_info)
    msg = messages[idx]
    content = msg[:content] || msg['content']
    return messages if content.to_s.include?('Current date/time:')

    copy = messages.dup
    copy[idx] = msg.merge(content: "#{content}\n\nCurrent date/time: #{date_info}")
    copy
  end

  def role_of(message)
    (message[:role] || message['role']).to_s
  end

  private :dated_user_at, :role_of, :promote_system_prefix, :with_dated_last_user
end
