#!/usr/bin/env ruby

$starbound_dir = ENV['STARBOUND_DIR'] || File.expand_path('~/Library/Application Support/Steam/SteamApps/common/Starbound')
$starbound_bin_dir = ENV['STARBOUND_BIN_DIR'] || File.join($starbound_dir, 'Starbound.app/Contents/MacOS')

$default_assets_pak = File.join($starbound_dir, 'assets/packed.pak')

$temp_path = File.absolute_path(File.join(File.dirname(__FILE__), 'temp'))
$output_path = File.absolute_path(File.join(File.dirname(__FILE__), 'output'))
$mods_to_override = %w{soy caffeine Starbooze cotton}

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

def find_mod mod
  installed_path = File.join($starbound_dir, 'mods', mod)
  if File.exists? installed_path
    installed_path
  else
    raise StandardError, "Cannot find mod #{mod} at #{installed_path}"
  end
end

mkdirp $temp_path
mkdirp $output_path

system File.join($starbound_bin_dir, 'asset_unpacker'), $default_assets_pak, File.join($temp_path, 'default_assets')
system 'ruby', File.join(File.dirname(__FILE__), 'generate.rb'), '-i', File.join($temp_path, 'default_assets'), '-o', $temp_path
rmrf File.join($temp_path, 'gravityless_plants') if File.exists?(File.join($temp_path, 'gravityless_plants'))
File.rename(File.join($temp_path, 'default_assets_gravityless_plants'), File.join($temp_path, 'gravityless_plants'))
File.delete File.join($output_path, 'gravityless_plants.zip') if File.exists? File.join($output_path, 'gravityless_plants.zip')
Dir.chdir $temp_path do
  system 'zip', '-q', '-r', File.join($output_path, 'gravityless_plants.zip'), 'gravityless_plants'
end
File.rename File.join($temp_path, 'gravityless_plants', 'gravityless_plants.modinfo'), File.join($temp_path, 'gravityless_plants', 'pak.modinfo')
system File.join($starbound_bin_dir, 'asset_packer'), File.join($temp_path, 'gravityless_plants'), File.join($output_path, 'gravityless_plants.modpak')

system 'ruby', File.join(File.dirname(__FILE__), 'generate.rb'), *$mods_to_override.flat_map { |mod| [ '-i', find_mod(mod) ] }, '-o', $temp_path
$mods_to_override.each do |mod|
  File.delete File.join($output_path, "#{mod}_gravityless_plants.zip") if File.exists? File.join($output_path, "#{mod}_gravityless_plants.zip")
  Dir.chdir $temp_path do
    system 'zip', '-q', '-r', File.join($output_path, "#{mod}_gravityless_plants.zip"), "#{mod}_gravityless_plants"
  end
  File.rename Dir[File.join($temp_path, "#{mod}_gravityless_plants", '*.modinfo')].first, File.join($temp_path, "#{mod}_gravityless_plants", 'pak.modinfo')
  system File.join($starbound_bin_dir, 'asset_packer'), File.join($temp_path, "#{mod}_gravityless_plants"), File.join($output_path, "#{mod}_gravityless_plants.modpak")
end
