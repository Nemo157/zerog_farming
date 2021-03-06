#!/usr/bin/env ruby

require 'bundler/setup'

require 'fileutils'
require 'pathname'

require_relative 'config'

$starbound_dir = ENV['STARBOUND_DIR'] || File.expand_path('~/Library/Application Support/Steam/SteamApps/common/Starbound')
$starbound_bin_dir = ENV['STARBOUND_BIN_DIR'] || File.join($starbound_dir, 'Starbound.app/Contents/MacOS')

$extra_mods_dir = File.absolute_path(File.join(File.dirname(__FILE__), 'mods'))

$default_assets_pak = File.join($starbound_dir, 'assets/packed.pak')

$temp_path = File.absolute_path(File.join(File.dirname(__FILE__), 'temp'))
$output_path = File.absolute_path(File.join(File.dirname(__FILE__), 'output', $config.version))

$mods = Dir.entries(File.join($starbound_dir, 'mods')).reject { |path| path == '.' || path == '..' || path.include?('zerog') }.map { |path| File.join($starbound_dir, 'mods', path) }
$mods += Dir.entries($extra_mods_dir).reject { |path| path == '.' || path == '..' || path.include?('zerog') }.map { |path| File.join($extra_mods_dir, path) }

$mods = $mods.select { |path| path.end_with?('.modpak') or Dir["#{path}/**/*.modinfo"].any? }

def rmrf path
  if File.file? path
    File.delete path
  elsif File.directory? path
    Dir.foreach(path) { |subpath| if (subpath != '.' && subpath != '..') then rmrf File.join(path, subpath) end }
    Dir.rmdir path
  end
end

def mkdirp path
  unless File.exists? path
    mkdirp File.dirname path
    Dir.mkdir path
  end
end

def cp_without_pak src, dst
  mkdirp dst unless File.exists? dst
  Dir.foreach(src).reject { |entry| entry == '.' || entry == '..' || entry.end_with?('pak') }.each do |entry|
    path = File.join(src, entry)
    if File.file? path
      FileUtils.cp(path, dst)
    else
      cp_without_pak path, File.join(dst, entry)
    end
  end
end

def unpack_if_needed mod
  if mod.end_with? '.modpak'
    puts "Unpacking #{mod}"
    unpacked_path = File.join($temp_path, File.basename(mod, '.modpak'))
    rmrf unpacked_path
    system File.join($starbound_bin_dir, 'asset_unpacker'), mod, unpacked_path
    unpacked_path
  elsif Dir["#{mod}/**/*.pak"].any?
    unpacked_path = File.join($temp_path, File.basename(mod))
    rmrf unpacked_path
    cp_without_pak mod, unpacked_path
    Dir["#{mod}/**/*.pak"].each do |pak|
      relative_path = Pathname.new(pak).relative_path_from(Pathname.new(mod))
      mkdirp File.join(unpacked_path, relative_path)
      system File.join($starbound_bin_dir, 'asset_unpacker'), pak, File.join(unpacked_path, relative_path)
    end
    unpacked_path
  else
    mod
  end
end

mkdirp $temp_path
mkdirp $output_path

system File.join($starbound_bin_dir, 'asset_unpacker'), $default_assets_pak, File.join($temp_path, 'default_assets')
system 'ruby', File.join(File.dirname(__FILE__), 'generate.rb'), '-i', File.join($temp_path, 'default_assets'), '-o', $temp_path
File.delete File.join($output_path, "#{$config.suffix}.modpak") if File.exists? File.join($output_path, "#{$config.suffix}.modpak")
File.rename File.join($temp_path, $config.suffix, "#{$config.suffix}.modinfo"), File.join($temp_path, $config.suffix, 'pak.modinfo')
system File.join($starbound_bin_dir, 'asset_packer'), File.join($temp_path, $config.suffix), File.join($output_path, "#{$config.suffix}.modpak")

system 'ruby', File.join(File.dirname(__FILE__), 'generate.rb'), *$mods.flat_map { |mod| [ '-i', unpack_if_needed(mod) ] }, '-o', $temp_path
$mods.each do |mod_path|
  mod = File.basename(mod_path, '.modpak')
  override = "#{mod}_#{$config.suffix}"
  if Dir["#{File.join($temp_path, override)}/**/*"].length < 2
    puts "Skipping packaging #{override} as it is empty"
  else
    File.delete File.join($output_path, "#{override}.modpak") if File.exists? File.join($output_path, "#{override}.modpak")
    File.rename Dir[File.join($temp_path, override, '*.modinfo')].first, File.join($temp_path, override, 'pak.modinfo')
    system File.join($starbound_bin_dir, 'asset_packer'), File.join($temp_path, override), File.join($output_path, "#{override}.modpak")
  end
end
