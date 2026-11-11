#!/usr/bin/env ruby
# `wayu build` reads entries.json and writes core.<ext> under the config
# lock: a write that lands while build waits for the lock (a concurrent
# `alias add`) is in the core build writes, never overwritten by a stale one.

require 'open3'
require 'fileutils'
require 'json'
require_relative 'test_helper'

class BuildLockIntegrationTest
  include WayuTestHelper

  def initialize
    setup_test_env
  end

  def run
    puts "🔒 Testing 'wayu build' under the config lock..."
    puts
    begin
      build_project
      initialize_wayu
      test_build_reads_entries_under_lock
    ensure
      teardown_test_env
    end
    print_summary('build lock')
    exit(@failed > 0 ? 1 : 0)
  end

  def check(ok, detail = '')
    if ok
      puts '✓'
      @passed += 1
    else
      puts '✗'
      puts "  #{detail}" unless detail.empty?
      @failed += 1
    end
  end

  def test_build_reads_entries_under_lock
    print 'Test 1: build waiting for the lock regenerates from the entries saved meanwhile... '
    py = `command -v python3 2>/dev/null`.strip
    if py.empty?
      puts 'skipped (python3 missing)'
      return
    end
    write_entries(aliases: { 'wayu_before' => 'true' })
    holder = IO.popen([py, '-I', '-c',
      'import fcntl, sys; f = open(sys.argv[1], "a+"); fcntl.lockf(f, fcntl.LOCK_EX); ' \
      'print("locked", flush=True); sys.stdin.readline()',
      "#{@data_dir}/.wayu.lock"], 'r+')
    holder.gets
    # The prompt-hook build: no script-build lock before generation.
    env = ENV.to_h.merge('HOME' => @tmp_home, 'WAYU_PROMPT_HOOK' => '1')
    _in, out, wait = Open3.popen2e(env, @wayu_bin, '--shell', 'zsh', 'build')
    sleep 0.5
    # What `alias add` does while it holds the lock.
    write_entries(aliases: { 'wayu_before' => 'true', 'wayu_added' => 'true' })
    holder.puts
    holder.close
    output = out.read
    status = wait.value
    core = File.read("#{@data_dir}/core.zsh")
    check(status.success? && core.include?('wayu_added'),
          "exit=#{status.exitstatus} has_added=#{core.include?('wayu_added')}\n#{output[0, 400]}")
  end
end

BuildLockIntegrationTest.new.run if __FILE__ == $0
