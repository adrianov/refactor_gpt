# frozen_string_literal: true

# Zeitwerk autoloading for lib; lib/superagent is collapsed so files define top-level constants.
# Shared types (SystemInfo, Utility, OpenAiClient, GeminiClient, etc.)
# live in lib; AskGptClient/AskGeminiClient are used by ask_gpt only.
# openai_client.rb defines OpenAiClient (capital I); Zeitwerk infers OpenaiClient from the path.
require 'zeitwerk'
loader = Zeitwerk::Loader.new
loader.push_dir(File.expand_path(__dir__))
loader.collapse(File.expand_path('superagent', __dir__))
loader.inflector.inflect("openai_client" => "OpenAiClient")
loader.inflector.inflect("openrouter_client" => "OpenrouterClient")
loader.setup
