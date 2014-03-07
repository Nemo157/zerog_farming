#!/usr/bin/env ruby

require 'bundler/setup'

require_relative 'config'

$tag = "v#{$config.version}"
$name = "#{$config.starbound_version} - Release #{$config.version.split('.').last}"
$output_path = File.absolute_path(File.join(File.dirname(__FILE__), 'output', $config.version))
$files = Dir.entries($output_path).reject { |path| path == '.' || path == '..' }.map { |path| File.join($output_path, path) }

$files = $files.reject { |file| file.end_with?('.DS_Store') }

puts "Tagging release"
if `git tag`.include? $tag
  puts "Tag #{$tag} already made"
else
  `git tag '#{$tag}'`
end
`git push --tags`

puts "Creating release"
$release_info = `github-release info -r zerog_farming | awk '/^-.*/ { echo = 0 } /^- #{Regexp.quote $tag}, name/ { echo = 1 } { if (echo == 1) { print } }'`.chomp
if $release_info.empty?
  `github-release release \
      --repo zerog_farming \
      --tag '#{$tag}' \
      --name '#{$name}'`
else
  puts "Release #{$name} already exists"
end

puts "Uploading files"
$files.each do |file|
  if $release_info.include? File.basename(file).gsub(/[\(\) ]+/, '.')
    puts "#{File.basename file} already released for #{$tag}"
  else
    puts "Uploading #{File.basename file} for #{$tag}"
    `github-release upload \
        --repo zerog_farming \
        --tag '#{$tag}' \
        --name '#{File.basename file}' \
        --file '#{file}'`
  end
end
