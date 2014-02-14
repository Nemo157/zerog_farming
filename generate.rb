#!/usr/bin/env ruby

require 'bundler/setup'

require 'optparse'
require 'ostruct'
require 'json'
require 'pathname'
require 'RMagick'

require_relative 'config'

options = OpenStruct.new
options.input = []
options.output = nil

OptionParser.new do |opts|
  opts.on("-i", "--input MOD", "Mod(s) to generate gravityless plants for, they should be unpacked and have a modinfo file") do |mod|
    options.input << mod
  end

  opts.on("-o", "--output OUTPUT", "Directory to output gravityless plants to") do |output|
    options.output = output
  end
end.tap do |parser|
  parser.parse!
  if options.input.empty?
    puts parser
    puts "Must specify at least one input mod"
    exit 2
  end
  if not options.output
    puts parser
    puts "Must specify an output directory"
    exit 2
  end
end

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

def to_hr obj
  if obj.is_a? OpenStruct
    Hash[obj.to_h.each_pair.map { |key, value| [ key, to_hr(value) ] }]
  elsif obj.is_a? Hash
    Hash[obj.each_pair.map { |key, value| [ key, to_hr(value) ] }]
  elsif obj.is_a? Array
    obj.map { |value| to_hr value }
  else
    obj
  end
end

class BaseFile
  attr_reader :glpg_metadata
  def initialize path, base_path
    @glpg_metadata = OpenStruct.new
    @glpg_metadata.path = path
    @glpg_metadata.root_path = base_path
    @glpg_metadata.relative_path = Pathname.new(path).relative_path_from(Pathname.new(base_path))
    @glpg_metadata.type = File.extname(path)[1..-1]
    @glpg_metadata.name = File.basename(path, ".#{@glpg_metadata.type}")
  end

  def self.get path, base_path
    @cache ||= {}
    @cache[path] ||= self.new(path, base_path)
  end
end

class BinaryFile < BaseFile
  attr_accessor :data
  def initialize path, base_path
    super
    if File.exists? path
      @data = File.open(path, 'rb') { |file| file.read }
    end
  end

  def save
    mkdirp(File.dirname glpg_metadata.path)
    File.open(glpg_metadata.path, 'wb') do |file|
      file.write @data
    end
  end
end

class JsonFile < BaseFile
  attr_reader :data
  def initialize path, base_path
    super
    if File.exists? path
      @data = JSON.parse(File.open(path) { |file| file.read }, symbolize_names: true, object_class: OpenStruct)
      @exists = true
    else
      @data = OpenStruct.new
      @exists = false
    end
  end

  def exists?
    return @exists
  end

  def respond_to_missing? method
    if method.end_with? '='
      true
    else
      @data.include? method
    end
  end

  def method_missing method, *args
    if method.to_s.end_with? '='
      @data[method.to_s.chomp('=').to_sym] = args.first
    else
      @data[method]
    end
  end

  def to_json *args
    to_hr(@data).to_json(*args)
  end

  def save
    mkdirp(File.dirname glpg_metadata.path)
    File.open(glpg_metadata.path, 'w') do |file|
      file.puts JSON.pretty_generate(self)
    end
  end
end

def is_json path
  File.open(path) do |file|
    begin
      JSON.parse(file.read)
      true
    rescue
      false
    end
  end
end

def find_modfile mod_path
  modinfos = Dir["#{mod_path}/*.modinfo"]
  if modinfos.count < 1
    JsonFile.get "#{mod_path}/#{File.basename mod_path}.modinfo", mod_path
  elsif modinfos.count > 1
    puts "Error: multiple .modinfo files found in #{mod_path}"
    exit 3
  else
    JsonFile.get modinfos.first, mod_path
  end
end

def find_files mod
  Dir["#{mod.glpg_metadata.root_path}/#{mod.path}/**/*"]
    .map { |path| File.absolute_path path }
    .select { |path| is_json path }
    .map { |path| JsonFile.get path, mod.glpg_metadata.root_path }
end

def find_objects mod
  find_files(mod).select { |file| file.glpg_metadata.type == 'object' }
end

def find_plants mod
  find_objects(mod).select { |object| object.objectType == 'farmable' }
end

def generate_frame_overrides frames, override_mod
  dir = File.join(override_mod.glpg_metadata.root_path, File.dirname(frames.glpg_metadata.relative_path))
  downwards = JsonFile.get File.join(dir, "#{frames.glpg_metadata.name}-downwards.frames"), override_mod.glpg_metadata.root_path
  leftwards = JsonFile.get File.join(dir, "#{frames.glpg_metadata.name}-leftwards.frames"), override_mod.glpg_metadata.root_path
  rightwards = JsonFile.get File.join(dir, "#{frames.glpg_metadata.name}-rightwards.frames"), override_mod.glpg_metadata.root_path

  if not downwards.frameGrid
    downwards.frameGrid = OpenStruct.new({
      size: frames.frameGrid.size,
      dimensions: frames.frameGrid.dimensions,
      names: frames.frameGrid.names.map { |row| row.reverse }.reverse
    })
    downwards.aliases = frames.aliases
  end

  if not leftwards.frameGrid
    leftwards.frameGrid = OpenStruct.new({
      size: frames.frameGrid.size.reverse,
      dimensions: frames.frameGrid.dimensions.reverse,
      names: frames.frameGrid.names.first.zip(*frames.frameGrid.names.drop(1)).reverse
    })
    leftwards.aliases = frames.aliases
  end

  if not rightwards.frameGrid
    rightwards.frameGrid = OpenStruct.new({
      size: frames.frameGrid.size.reverse,
      dimensions: frames.frameGrid.dimensions.reverse,
      names: frames.frameGrid.names.first.zip(*frames.frameGrid.names.drop(1))
    })
    rightwards.aliases = frames.aliases
  end


  [ downwards, leftwards, rightwards ]
end

def generate_image_overrides frames, image, override_mod
  dir = File.join(override_mod.glpg_metadata.root_path, File.dirname(frames.glpg_metadata.relative_path))
  downwards = BinaryFile.get File.join(dir, "#{image.glpg_metadata.name}-downwards.#{image.glpg_metadata.type}"), override_mod.glpg_metadata.root_path
  leftwards = BinaryFile.get File.join(dir, "#{image.glpg_metadata.name}-leftwards.#{image.glpg_metadata.type}"), override_mod.glpg_metadata.root_path
  rightwards = BinaryFile.get File.join(dir, "#{image.glpg_metadata.name}-rightwards.#{image.glpg_metadata.type}"), override_mod.glpg_metadata.root_path

  if not downwards.data
    downwards.data = Magick::Image.from_blob(image.data).first.rotate(180).to_blob
  end

  if not leftwards.data
    leftwards.data = Magick::Image.from_blob(image.data).first.rotate(-90).to_blob
  end

  if not rightwards.data
    rightwards.data = Magick::Image.from_blob(image.data).first.rotate(90).to_blob
  end

  OpenStruct.new({
    downwards: downwards,
    leftwards: leftwards,
    rightwards: rightwards,
    all: [ downwards, leftwards, rightwards ]
  })
end

def generate_plant_override plant, override_mod, images, image_options
  file_path = File.join(override_mod.glpg_metadata.root_path, plant.glpg_metadata.relative_path)

  JsonFile.get(file_path, override_mod.glpg_metadata.root_path).tap do |object_override|
    object_override.__merge = [
      [ "overwrite", "orientations" ]
    ]
    object_override.orientations = [
      plant.orientations.first.tap do |top|
        top[:spaces] = (0...(plant.glpg_metadata.height)).flat_map { |y| (0...(plant.glpg_metadata.width)).map { |x| [x, y] } }
        top.delete_field(:anchors)
        top[:fgAnchors] = (0...(plant.glpg_metadata.width)).map { |val| [val, -1] }
      end,
    {
      dualImage: "#{Pathname.new(images.downwards.glpg_metadata.path).relative_path_from(Pathname.new(File.dirname(file_path)))}:#{image_options}",
      imagePosition: [0, -((plant.glpg_metadata.height - 1) * 8)],
      frames: 1,
      animationCycle: 0.5,
      spaceScan: 0.1,
      requireSoilAnchors: true,
      requireTilledAnchors: false,
      spaces: (0...(plant.glpg_metadata.height)).flat_map { |y| (0...(plant.glpg_metadata.width)).map { |x| [x, -y] } },
      fgAnchors: (0...(plant.glpg_metadata.width)).map { |val| [val, 1] }
    }, {
      image: "#{Pathname.new(images.leftwards.glpg_metadata.path).relative_path_from(Pathname.new(File.dirname(file_path)))}:#{image_options}",
      imagePosition: [-((plant.glpg_metadata.height - 1) * 8), 0],
      frames: 1,
      animationCycle: 0.5,
      spaceScan: 0.1,
      requireSoilAnchors: true,
      requireTilledAnchors: false,
      spaces: (0...(plant.glpg_metadata.height)).flat_map { |y| (0...(plant.glpg_metadata.width)).map { |x| [-y, x] } },
      fgAnchors: (0...(plant.glpg_metadata.width)).map { |val| [1, val] }
    }, {
      image: "#{Pathname.new(images.rightwards.glpg_metadata.path).relative_path_from(Pathname.new(File.dirname(file_path)))}:#{image_options}",
      imagePosition: [0, 0],
      frames: 1,
      animationCycle: 0.5,
      spaceScan: 0.1,
      requireSoilAnchors: true,
      requireTilledAnchors: false,
      spaces: (0...(plant.glpg_metadata.height)).flat_map { |y| (0...(plant.glpg_metadata.width)).map { |x| [y, x] } },
      fgAnchors: (0...(plant.glpg_metadata.width)).map { |val| [-1, val] }
    }]
  end
end

def generate_plant_overrides plant, override_mod
  image_details = plant.orientations.first.dualImage
  image_path, image_options = image_details.split(':')
  image = BinaryFile.get File.absolute_path(File.join(File.dirname(plant.glpg_metadata.path), image_path)), plant.glpg_metadata.root_path

  frames = JsonFile.get File.join(File.dirname(plant.glpg_metadata.path), File.basename(image_path, File.extname(image_path)) + ".frames"), plant.glpg_metadata.root_path
  plant.glpg_metadata.width = (frames.frameGrid.size[0] / 8.0).ceil
  plant.glpg_metadata.height = (frames.frameGrid.size[1] / 8.0).ceil

  frame_overrides = generate_frame_overrides frames, override_mod
  image_overrides = generate_image_overrides frames, image, override_mod
  object_override = generate_plant_override plant, override_mod, image_overrides, image_options
  return frame_overrides + image_overrides.all + [object_override]
end

def generate_override_modfile mod, override_mod_path
  override_mod_name = mod.exists? ? "#{mod.name}_#{$config.suffix}" : $config.suffix
  JsonFile.get(File.join(override_mod_path, override_mod_name + '.modinfo'), override_mod_path).tap do |override_mod|
    override_mod.name = override_mod_name
    override_mod.version = mod.version || $config.default_starbound_version
    override_mod.dependencies = [ mod.name ] if mod.exists?
    override_mod.path = mod.path || '.'
    override_mod.metadata = OpenStruct.new({
      version: $config.version,
      author: $config.author,
      description: mod.exists? ? "#{$config.description} for #{mod.name}" : $config.description,
      support_url: $config.support_url
    })
  end
end

@output_files = []
puts "Outputting all mods to #{options.output}"
options.input.map { |mod_path| find_modfile File.absolute_path mod_path }.each do |mod|
  if mod.exists?
    override_mod_path = File.absolute_path(File.join(options.output, "#{File.basename mod.glpg_metadata.root_path}_#{$config.suffix}"))
  else
    override_mod_path = File.absolute_path(File.join(options.output, $config.suffix))
  end
  rmrf override_mod_path
  override_mod = generate_override_modfile mod, override_mod_path
  @output_files << override_mod
  puts "Generating #{File.basename override_mod_path}/#{override_mod.name} to override #{File.basename mod.glpg_metadata.root_path}/#{mod.name}"
  find_plants(mod).each do |plant|
    generate_plant_overrides(plant, override_mod).each do |file|
      @output_files << file
    end
  end
end

@output_files.uniq!

puts "Generated #{@output_files.count} files"
@output_files.each do |file|
  file.save
end
