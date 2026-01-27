#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'

sounds_dir = File.join(__dir__, 'sounds')
FileUtils.mkdir_p(sounds_dir)

system_sounds = {
  'success.aiff' => '/System/Library/Sounds/Glass.aiff',
  'error.aiff' => '/System/Library/Sounds/Basso.aiff'
}

system_sounds.each do |dest_name, source_path|
  if File.exist?(source_path)
    dest_path = File.join(sounds_dir, dest_name)
    FileUtils.cp(source_path, dest_path)
    puts "Copied #{source_path} -> #{dest_path}"
  else
    puts "Warning: #{source_path} not found"
  end
end

puts "Done! Sounds copied to #{sounds_dir}"
