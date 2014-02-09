#!/usr/bin/env ruby

require 'optparse'
require 'ostruct'
require 'json'
require 'pathname'
require 'RMagick'

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

def to_hr struct
  struct.to_h.tap do |hash|
    hash.each_pair do |key, value|
      if value.is_a? OpenStruct
        hash[key] = to_hr value
      end
    end
  end
end

class BaseFile
  attr_reader :metadata
  def initialize path, base_path
    @metadata = OpenStruct.new
    @metadata.path = path
    @metadata.root_path = base_path
    @metadata.relative_path = Pathname.new(path).relative_path_from(Pathname.new(base_path))
    @metadata.type = File.extname(path)[1..-1]
    @metadata.name = File.basename(path, ".#{@metadata.type}")
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
    mkdirp(File.dirname metadata.path)
    File.open(metadata.path, 'wb') do |file|
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
    else
      @data = OpenStruct.new
    end
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
    mkdirp(File.dirname metadata.path)
    File.open(metadata.path, 'w') do |file|
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
    puts "Error: no .modinfo files found in #{mod_path}"
    exit 3
  end
  if modinfos.count > 1
    puts "Error: multiple .modinfo files found in #{mod_path}"
    exit 3
  end
  JsonFile.get modinfos.first, mod_path
end

def find_files mod
  Dir["#{mod.metadata.root_path}/#{mod.path}/**/*"]
    .map { |path| File.absolute_path path }
    .select { |path| is_json path }
    .map { |path| JsonFile.get path, mod.metadata.root_path }
end

def find_objects mod
  find_files(mod).select { |file| file.metadata.type == 'object' }
end

def find_plants mod
  find_objects(mod).select { |object| object.objectType == 'farmable' }
end

def generate_frame_overrides frames, override_mod
  dir = File.join(override_mod.metadata.root_path, File.dirname(frames.metadata.relative_path))
  downwards = JsonFile.get File.join(dir, "#{frames.metadata.name}-downwards.frames"), override_mod.metadata.root_path
  leftwards = JsonFile.get File.join(dir, "#{frames.metadata.name}-leftwards.frames"), override_mod.metadata.root_path
  rightwards = JsonFile.get File.join(dir, "#{frames.metadata.name}-rightwards.frames"), override_mod.metadata.root_path

  if not downwards.frameGrid
    downwards.frameGrid = OpenStruct.new({
      size: frames.frameGrid.size,
      dimensions: frames.frameGrid.dimensions,
      names: frames.frameGrid.names
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
  dir = File.join(override_mod.metadata.root_path, File.dirname(frames.metadata.relative_path))
  downwards = BinaryFile.get File.join(dir, "#{image.metadata.name}-downwards.#{image.metadata.type}"), override_mod.metadata.root_path
  leftwards = BinaryFile.get File.join(dir, "#{image.metadata.name}-leftwards.#{image.metadata.type}"), override_mod.metadata.root_path
  rightwards = BinaryFile.get File.join(dir, "#{image.metadata.name}-rightwards.#{image.metadata.type}"), override_mod.metadata.root_path

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
  file_path = File.join(override_mod.metadata.root_path, plant.metadata.relative_path)

  JsonFile.get(file_path, override_mod.metadata.root_path).tap do |object_override|
    object_override.__merge = []
    object_override.orientations = {
      __merge: [
        "list",
        [ "update", {
          anchors: [ "bottom" ]
        }, {
          spaces: (0...(plant.metadata.height)).flat_map { |y| (0...(plant.metadata.width)).map { |x| [x, y] } }
        }],
        [ "append", {
          dualImage: "#{Pathname.new(images.downwards.metadata.path).relative_path_from(Pathname.new(File.dirname(file_path)))}:#{image_options}",
          imagePosition: [0, -((plant.metadata.height - 1) * 8)],
          frames: 1,
          animationCycle: 0.5,
          spaceScan: 0.1,
          requireTilledAnchors: false,
          spaces: (0...(plant.metadata.height)).flat_map { |y| (0...(plant.metadata.width)).map { |x| [x, -y] } },
          anchors: [ "top" ]
        }],
        [ "append", {
          dualImage: "#{Pathname.new(images.leftwards.metadata.path).relative_path_from(Pathname.new(File.dirname(file_path)))}:#{image_options}",
          imagePosition: [0, 0],
          frames: 1,
          animationCycle: 0.5,
          spaceScan: 0.1,
          requireTilledAnchors: false,
          spaces: (0...(plant.metadata.height)).flat_map { |y| (0...(plant.metadata.width)).map { |x| [-y, x] } },
          fgAnchors: (0...(plant.metadata.width)).map { |val| [1, val] }
        }],
        [ "append", {
          dualImage: "#{Pathname.new(images.rightwards.metadata.path).relative_path_from(Pathname.new(File.dirname(file_path)))}:#{image_options}",
          imagePosition: [-((plant.metadata.height - 1) * 8), 0],
          frames: 1,
          animationCycle: 0.5,
          spaceScan: 0.1,
          requireTilledAnchors: false,
          spaces: (0...(plant.metadata.height)).flat_map { |y| (0...(plant.metadata.width)).map { |x| [y, x] } },
          fgAnchors: (0...(plant.metadata.width)).map { |val| [-1, val] }
        }]
      ]
    }
  end
end

def generate_plant_overrides plant, override_mod
  image_details = plant.orientations.first.dualImage
  image_path, image_options = image_details.split(':')
  image = BinaryFile.get File.absolute_path(File.join(File.dirname(plant.metadata.path), image_path)), plant.metadata.root_path

  frames = JsonFile.get File.join(File.dirname(plant.metadata.path), File.basename(image_path, File.extname(image_path)) + ".frames"), plant.metadata.root_path
  plant.metadata.width = (frames.frameGrid.size[0] / 8.0).ceil
  plant.metadata.height = (frames.frameGrid.size[1] / 8.0).ceil

  frame_overrides = generate_frame_overrides frames, override_mod
  image_overrides = generate_image_overrides frames, image, override_mod
  object_override = generate_plant_override plant, override_mod, image_overrides, image_options
  return frame_overrides + image_overrides.all + [object_override]
end

def generate_override_modfile mod, override_mod_path
  override_mod_name = mod.name + '_gravityless_plants'
  JsonFile.get(File.join(override_mod_path, override_mod_name + '.modinfo'), override_mod_path).tap do |override_mod|
    override_mod.name = override_mod_name
    override_mod.version = mod.version
    override_mod.dependencies = [ mod.name ]
    override_mod.path = mod.path
  end
end

@output_files = []
puts "Outputting all mods to #{options.output}"
options.input.map { |mod_path| find_modfile File.absolute_path mod_path }.each do |mod|
  override_mod_path = File.absolute_path(File.join options.output, "#{File.basename mod.metadata.root_path}_gravityless_plants")
  rmrf override_mod_path
  override_mod = generate_override_modfile mod, override_mod_path
  @output_files << override_mod
  puts "Generating #{File.basename override_mod_path}/#{override_mod.name} to override #{File.basename mod.metadata.root_path}/#{mod.name}"
  find_plants(mod).each do |plant|
    puts "Found plant in mod #{mod.name} at #{plant.metadata.relative_path}"
    generate_plant_overrides(plant, override_mod).each do |file|
      @output_files << file
    end
  end
end

@output_files.uniq!

puts ""
puts "Generated Files"
puts "==============="
@output_files.each do |file|
  puts "#{file.metadata.path}"
  file.save
end
