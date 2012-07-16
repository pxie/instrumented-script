#!/usr/bin/env ruby
require 'optparse'
require 'fileutils'

def save_gemfile(file_handler, data)
  # insert gem "simplecov" at second line

  simplecov_str = "gem 'simplecov'\ngem 'simplecov-rcov'\n"
  data.insert(1, simplecov_str)
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
    exec("bundle update simplecov simplecov-rcov") if fork == nil
    Process.wait
  end
end

def do_insert_simplecov_start(comp, vcap_src_home, start_script)
  unless File.exist?(start_script)
    raise RuntimeError, "Cannot find start script: #{start_script}"
  end

  process = File.basename(start_script)
  if $simplecov_format
    rcov_str = nil
  else
    rcov_str = "require 'simplecov-rcov'\nSimpleCov.formatter = SimpleCov::Formatter::RcovFormatter\n"
  end
  if comp == 'cloud_controller'
    code_block = "require 'simplecov'\n" +
        "#{rcov_str}" +
        "SimpleCov.start 'rails' do\n  root '#{vcap_src_home}'\n" +
        "  command_name '#{process}'\n  merge_timeout 3600\nend\n"
  else
    code_block = "require 'simplecov'\n" +
        "#{rcov_str}" +
        "SimpleCov.start do\n  root '#{vcap_src_home}'\n" +
        "  command_name '#{process}'\n  merge_timeout 3600\nend\n"
  end
  file = open(start_script, "r+")
  data = file.readlines
  data.insert(1, code_block)
  file.rewind
  file.write(data.join(""))
  file.close
end

def grace_exit(vcap_src_home)
  stop_script = open(File.join(vcap_src_home, 'dev_setup/bin/vcap'), "r+")
  target_str = "# Return status if we succeeded in stopping"
  code_block = "    while running?\n      sleep(1)\n    end\n"
  data = stop_script.readlines
  stop_script.rewind
  data.insert(data.index {|x| x =~ /#{target_str}/}, code_block)
  stop_script.write(data.join(""))
  stop_script.close
end

def add_simplecov_start(vcap_src_home, component)

  case component
    when 'cloud_controller', 'health_manager'
      start_script = File.join(vcap_src_home, "../cloud_controller/#{component}/bin/#{component}")
      do_insert_simplecov_start(component, vcap_src_home, start_script)
    when 'router', 'dea', 'uaa'
      start_script = File.join(vcap_src_home, "../#{component}/bin/#{component}")
      do_insert_simplecov_start(component, vcap_src_home, start_script)
    when 'redis', 'mysql', 'mongodb', 'rabbit', 'neo4j', 'memcached', 'postgresql', 'vblob',
          'echo', 'elasticsearch', 'couchdb'
      start_script = File.join(vcap_src_home, "services/#{component}/bin/#{component}_node")
      do_insert_simplecov_start(component, vcap_src_home, start_script)

      start_script = File.join(vcap_src_home, "services/#{component}/bin/#{component}_gateway")
      do_insert_simplecov_start(component, vcap_src_home, start_script)
    when 'filesystem'
      start_script = File.join(vcap_src_home, "services/#{component}/bin/#{component}_gateway")
      do_insert_simplecov_start(component, vcap_src_home, start_script)
    else
      raise RuntimeError, "component: #{component} is not supported"
  end
end

def modify_cc_start(vcap_src_home)
  start_script = File.join(vcap_src_home, "bin/cloud_controller")
  dest_script = "#{start_script}.rb"
  FileUtils.cp(start_script, dest_script)
  code_block = "#!/usr/bin/env ruby\n$:.unshift(File.dirname(__FILE__))\nrequire 'cloud_controller'\n"
  open(start_script, "w") do |f|
    f.write(code_block)
  end

end
def instrument(vcap_src_home)
  modify_cc_start(vcap_src_home)

  core_components = %w(cloud_controller router health_manager dea uaa)
  core_components.each do |comp|
    path = File.join(vcap_src_home, comp)
    install_simplecov(path)
    add_simplecov_start(vcap_src_home, comp)
  end

  services = %w(redis mysql mongodb rabbit neo4j memcached filesystem vblob postgresql echo
                  elasticsearch couchdb service_broker serialization_data_server)
  services.each do |service|
    path = File.join(vcap_src_home, "services", service)
    install_simplecov(path)
    add_simplecov_start(vcap_src_home, service)
  end
  grace_exit(vcap_src_home)
end

def reset(vcap_src_home)
  Dir.chdir(vcap_src_home)
  exec("git reset --hard") if fork == nil
  Process.wait

  Dir.chdir(File.join(vcap_src_home, "services"))
  exec("git reset --hard") if fork == nil
  Process.wait

  Dir.chdir(File.join(vcap_src_home, "uaa"))
  exec("git reset --hard") if fork == nil
  Process.wait

  coverage_dir = File.join(vcap_src_home, "coverage")
  FileUtils.remove_dir(coverage_dir) if Dir.exist?(coverage_dir)
end



# This hash will hold all of the options
# parsed from the command-line by
# OptionParser.
options = {}

optparse = OptionParser.new do|opts|
  # Set a banner, displayed at the top
  # of the help screen.
  opts.banner = "Usage: instrumented.rb [options] VCAP_SRC_HOME"

  options[:insert] = false
  opts.on( '-i', '--insert', 'Insert simplecov code into dev_setup source' ) do
    options[:insert] = true
  end

  options[:simplecov_format] = false
  opts.on( '--simplecov-format', "Use simplecov report format, default is rcov report format. " +
      "This option only works for -i, --insert" ) do
    options[:simplecov_format] = true
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
  puts "start instrumenting"
  $simplecov_format = options[:simplecov_format]
  instrument(vcap_src_home)
elsif options[:reset]
  puts "start resetting"
  reset(vcap_src_home)
end
puts "end game"
