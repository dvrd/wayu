#!/usr/bin/env ruby
require_relative 'test_helper'
require 'optparse'

class PublicationTest
  include WayuTestHelper

  def initialize
    setup_test_env
    build_project
  end

  def cli(*args, code: 0)
    env = { 'HOME' => @tmp_home, 'SHELL' => '/bin/bash', 'NO_COLOR' => '1' }
    out, err, status = Open3.capture3(env, @wayu_bin, *args)
    raise "#{args.inspect}: expected #{code}, got #{status.exitstatus}\n#{out}\n#{err}" unless status.exitstatus == code
    [out, err]
  end

  def run(group)
    if group == 'entry'
      cli('-c', 'echo native')
      raise 'native command created a host runtime' unless Dir.glob(File.join(@data_dir, '{init,core}.*')).empty?
    end
    cli('init', '--shell', 'bash')
    cli('init', '--shell', 'zsh')
    core = File.join(@data_dir, 'core.bash')
    File.unlink(core)
    Dir.mkdir(core)
    case group
    when 'entry'
      out, err = cli('alias', 'add', 'publication_probe', 'printf ready', code: 74)
      raise "missing partial-save diagnostic: #{err}" unless err.include?(core) && err.include?('saved') && err.include?('wayu build')
      raise "unqualified success: #{out}" if out.include?('Alias added')
      raise 'missing stored alias' unless cli('alias', 'get', 'publication_probe').first.include?('printf ready')
      raise 'other shell was left stale' unless File.read(File.join(@data_dir, 'core.zsh')).include?('publication_probe')
      cli('build', code: 74)
      cli('init', '--shell', 'bash', code: 74)
      cli('const', 'add', 'PUBLICATION_VAR', 'persisted', code: 74)
      Dir.mkdir(File.join(@tmp_home, 'publication-probe'))
      cli('path', 'add', File.join(@tmp_home, 'publication-probe'), code: 74)
      cli('alias', 'add', 'preview', 'true', '--dry-run')
      Dir.rmdir(core)
      2.times { cli('build') }
      output, status = Open3.capture2e({ 'HOME' => @tmp_home }, '/bin/bash', '--noprofile', '--norc',
                                       '-c', 'source "$1" && alias publication_probe', 'bash',
                                       File.join(@data_dir, 'init.bash'))
      raise "fresh Bash: #{output}" unless status.success? && output.include?('printf ready')
    when 'config'
      cli('reload', 'regenerate', code: 74)
      plugins = File.join(@data_dir, 'plugins.json')
      previous = File.binread(plugins) if File.file?(plugins)
      File.write(plugins, '{')
      cli('build', code: 78)
      cli('init', '--shell', 'bash', code: 78)
      previous ? File.binwrite(plugins, previous) : File.unlink(plugins)
      Dir.rmdir(core)
      cli('reload', 'regenerate')
      %w[path_sync.bash turbo.bash init.bash].each do |file|
        cli('export', '--shell', 'bash') if file == 'turbo.bash'
        path = File.join(@data_dir, file)
        File.unlink(path)
        Dir.mkdir(path)
        _, err = cli('build', code: 74)
        raise "missing failed artifact #{file}" unless err.include?(path)
        Dir.rmdir(path)
        cli('init', '--shell', 'bash') if file == 'init.bash'
        cli('build')
      end
    when 'repair'
      cli('alias', 'add', 'repair_probe', 'true', code: 74)
      cli('alias', 'add', 'repair_probe', 'false', code: 74)
      cli('backup', 'restore', 'alias', '--yes', code: 74)
      Dir.rmdir(core)
      cli('build')
    end
  ensure
    teardown_test_env
  end
end

group = 'all'
OptionParser.new { |p| p.on('--group GROUP', %w[all entry config repair]) { |v| group = v } }.parse!
(group == 'all' ? %w[entry config repair] : [group]).each { |name| PublicationTest.new.run(name) }
