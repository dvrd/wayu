#!/usr/bin/env ruby
# Exercise the actual plugin-get clipboard call in an isolated HOME.
require 'open3'
require 'json'
require 'fileutils'
require_relative 'test_helper'

class ClipboardTest
  include WayuTestHelper

  def initialize
    setup_test_env
  end

  def run
    begin
      build_project
      initialize_wayu
      fake_bin = "#{@tmp_home}/clipboard-bin"
      FileUtils.mkdir_p(fake_bin)
      plugin_dir = "#{@data_dir}/plugins/demo"
      FileUtils.mkdir_p(plugin_dir)
      url = 'https://example.invalid/' + 'x' * 131_072
      File.write("#{@data_dir}/plugins.json", JSON.generate(
        'version' => '1.0', 'plugins' => [{
          'name' => 'demo', 'url' => url, 'enabled' => true,
          'shell' => 'zsh', 'installedPath' => plugin_dir,
          'template' => 'source', 'priority' => 100, 'git' => {}, 'use' => []
        }]
      ))
      env = sanitizer_env.merge('HOME' => @tmp_home,
                                'PATH' => "#{fake_bin}:/usr/bin:/bin",
                                'WAYU_CLIP_FIXTURE' => "#{@tmp_home}/copied")
      %w[pbcopy xclip xsel].each do |name|
        path = "#{fake_bin}/#{name}"
        File.write(path, "#!/bin/sh\nexec 0<&-\nsleep 0.05\n")
        FileUtils.chmod(0755, path)
      end
      out, err, status = Open3.capture3(env, @wayu_bin, 'plugin', 'get', 'demo')
      abort "clipboard close killed wayu: #{status}\n#{err}" unless
        status.success? && (out + err).include?('Failed to copy URL')
      puts 'PASS clipboard: an early reader close reports failure without SIGPIPE'

      %w[pbcopy xclip xsel].each do |name|
        File.write("#{fake_bin}/#{name}", "#!/bin/sh\ncat > \"$WAYU_CLIP_FIXTURE\"\n")
      end
      out, err, status = Open3.capture3(env, @wayu_bin, 'plugin', 'get', 'demo')
      abort "clipboard transfer failed: #{status}\n#{err}" unless
        status.success? && (out + err).include?('URL copied to clipboard') &&
        File.binread("#{@tmp_home}/copied") == url
      puts 'PASS clipboard: the complete large URL reaches the helper'

      # Clipboard owners such as xclip can fork a background daemon. Its
      # inherited output must not hold a capture pipe open in wayu.
      %w[pbcopy xclip xsel].each do |name|
        File.write("#{fake_bin}/#{name}", "#!/bin/sh\ncat > \"$WAYU_CLIP_FIXTURE\"\nsleep 4 &\n")
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out, err, status = Open3.capture3(env, @wayu_bin, 'plugin', 'get', 'demo')
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      abort "background clipboard owner delayed wayu: #{elapsed}s" unless
        status.success? && elapsed < 3 && (out + err).include?('URL copied to clipboard')
      puts 'PASS clipboard: a background owner does not delay foreground completion'
    ensure
      teardown_test_env
    end
  end
end

ClipboardTest.new.run if __FILE__ == $0
