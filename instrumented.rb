#!/usr/bin/env ruby
# A script that will pretend to resize a number of images
require 'optparse'
require "ruby-debug"
SIMPLECOV_STR = "gem 'simplecov'\n"

def save_gemfile(file_handler, data)
  # insert gem "simplecov" at second line
  data.insert(1, SIMPLECOV_STR)
  file_handler.rewind
  file_handler.write(data.join(""))
  file_handler.close
end

def install_simplecov(path)
  gemfile = open(File.join(path, "Gemfile"), "r")
  data = gemfile.readlines
  gemfile.close
  gemfile = open(File.join(path, "Gemfile"), "w")
  if data.select {|line| line =~ /simplecov/}.empty?
    save_gemfile(gemfile, data)
    Dir.chdir(path)
    exec("bundle install") if fork == nil
    Process.wait
  else
    # remove original gem "simplecov"
    data.select! {|line| !(line =~ /simplecov/)}
    save_gemfile(gemfile, data)
    Dir.chdir(path)
    exec("bundle update simplecov") if fork == nil
    Process.wait
  end
end

def do_insert_simplecov_start(vcap_src_home, start_script)
  unless File.exist?(start_script)
    raise RuntimeError, "Cannot find start script: #{start_script}"
  end

  process = File.basename(start_script)
  code_block = "require 'simplecov'\nSimpleCov.start do\n  root '#{vcap_src_home}'\n" +
    "  command_name '#{process}'\n  merge_timeout 3600\nend\n"
  file = open(start_script, "r+")
  data = file.readlines
  data.insert(1, code_block)
  file.rewind
  file.write(data.join(""))
  file.close
end

def add_simplecov_start(vcap_src_home, component)

  case component
    when 'cloud_controller'
      start_script = File.join(vcap_src_home, "bin/#{component}")
      do_insert_simplecov_start(vcap_src_home, start_script)
    when 'router', 'health_manager', 'dea', 'uaa'
      start_script = File.join(vcap_src_home, "#{component}/bin/#{component}")
      do_insert_simplecov_start(vcap_src_home, start_script)
    when 'redis', 'mysql', 'mongodb', 'rabbit', 'neo4j', 'memcached'
      start_script = File.join(vcap_src_home, "services/#{component}/bin/#{component}_node")
      do_insert_simplecov_start(vcap_src_home, start_script)

      start_script = File.join(vcap_src_home, "services/#{component}/bin/#{component}_gateway")
      do_insert_simplecov_start(vcap_src_home, start_script)
    else
      raise RuntimeError, "component: #{component} is not supported"
  end
end

def instrument(vcap_src_home)
  core_components = %w(cloud_controller router health_manager dea uaa)

  core_components.each do |comp|
    path = File.join(vcap_src_home, comp)
    install_simplecov(path)
    add_simplecov_start(vcap_src_home, comp)
  end

  breakpoint
  services = %w(redis mysql mongodb rabbit neo4j memcached)
  services.each do |service|
    path = File.join(vcap_src_home, "services", service)
    install_simplecov(path)
    add_simplecov_start(vcap_src_home, service)
  end
end

def reset(vcap_src_home)
  Dir.chdir(vcap_src_home)
  exec("git reset --hard")
  `git reset --hard`
  `cd services`
  `git reset --hard`
  `cd ../uaa`
  `git reset --hard`
end



# This hash will hold all of the options
# parsed from the command-line by
# OptionParser.
options = {}

optparse = OptionParser.new do|opts|
  # Set a banner, displayed at the top
  # of the help screen.
  opts.banner = "Usage: instrumented.rb [options] VCAP_SRC_HOME"

  # Define the options, and what they do
  options[:verbose] = false
  opts.on( '-v', '--verbose', 'Output more information' ) do
    options[:verbose] = true
  end

  options[:insert] = false
  opts.on( '-i', '--insert', 'Insert simplecov code into dev_setup source' ) do
    options[:insert] = true
  end

  options[:reset] = false
  opts.on( '-r', '--reset', 'reset dev_setup source code back to normal' ) do
    options[:reset] = true
  end

  # This displays the help screen, all programs are
  # assumed to have this option.
  opts.on( '-h', '--help', 'Display this screen' ) do
    puts opts
    exit
  end
end

# Parse the command-line. Remember there are two forms
# of the parse method. The 'parse' method simply parses
# ARGV, while the 'parse!' method parses ARGV and removes
# any options found there, as well as any parameters for
# the options. What's left is the list of files to resize.
optparse.parse!

vcap_src_home = File.absolute_path(ARGV.first)
unless File.directory?(vcap_src_home)
  raise RuntimeError, "invalid file path input"
end

if options[:insert]
  breakpoint
  puts "start instrumenting"
  instrument(vcap_src_home)
elsif options[:reset]
  breakpoint
  puts "start resetting"
  instrument(vcap_src_home)
end
puts "Being verbose" if options[:verbose]
puts "Being quick" if options[:quick]
puts "Logging to file #{options[:logfile]}" if options[:logfile]

