# frozen_string_literal: true

# Zeitwerk autoloading for lib. Collapsed subdirs (git_commit, git_explain,
# primary_api) define top-level constants.
# Shared types (SystemInfo, Utility, OpenrouterClient, etc.)
# live in lib; AskGptClient is used by ask_gpt only.
REFACTOR_GPT_ROOT = File.expand_path('..', __dir__).freeze
# Aliases follow cwd Ruby and Bundler; this process must use the project's interpreter and gems.
wanted_ruby = File.read(File.join(REFACTOR_GPT_ROOT, '.ruby-version')).strip
rbenv_ruby = File.expand_path("~/.rbenv/versions/#{wanted_ruby}/bin/ruby")
foreign_bundle = ENV['BUNDLE_GEMFILE'] &&
  File.expand_path(ENV['BUNDLE_GEMFILE']) != File.join(REFACTOR_GPT_ROOT, 'Gemfile')
if (RUBY_VERSION != wanted_ruby || foreign_bundle) && File.executable?(rbenv_ruby) && File.file?($PROGRAM_NAME)
  ENV.delete_if { |key, _| key.start_with?('BUNDLE_', 'BUNDLER_') }
  rubyopt = ENV.delete('RUBYOPT').to_s.gsub(/(?:^|\s)-r\s*bundler\/setup/, '').strip
  ENV['RUBYOPT'] = rubyopt unless rubyopt.empty?
  ENV.delete('GEM_HOME')
  ENV.delete('GEM_PATH')
  exec(rbenv_ruby, File.expand_path($PROGRAM_NAME), *ARGV)
end
require 'zeitwerk'
loader = Zeitwerk::Loader.new
loader.push_dir(File.expand_path(__dir__))
loader.collapse(File.expand_path('git_commit', __dir__))
loader.collapse(File.expand_path('git_explain', __dir__))
loader.collapse(File.expand_path('primary_api', __dir__))
loader.inflector.inflect("openrouter_client" => "OpenrouterClient")
loader.setup
