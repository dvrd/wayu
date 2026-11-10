#!/usr/bin/env ruby
# Integration tests for `wayu watch` (`reload`): the running watcher is the
# holder of <data>/watcher.lock, so `stop` / `status` never trust a PID file
# alone and never signal a process that is not the watcher (OKAMI-316).

require 'open3'
require 'fileutils'
require 'timeout'
require_relative 'test_helper'

class WatchIntegrationTest
  include WayuTestHelper

  def initialize
    setup_test_env
  end

  def run
    puts "👀 Testing watch integration..."
    puts

    begin
      build_project
      initialize_wayu(shell: 'zsh')

      test_stale_pid_file_not_signalled
      test_start_status_stop
    ensure
      teardown_test_env
    end

    print_summary("watch")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def pid_file; "#{@data_dir}/watcher.pid"; end

  def check(label, condition, detail = nil)
    print "#{label}... "
    if condition
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  #{detail}" if detail
      @failed += 1
    end
  end

  # Our child `pid` has not exited (a killed child is reaped here, so a
  # zombie does not count as alive).
  def alive?(pid)
    Process.waitpid(pid, Process::WNOHANG).nil?
  rescue Errno::ECHILD
    false
  end

  # Regression (OKAMI-316): a PID file left by a dead watcher named a PID
  # the OS had reused; `watch stop` SIGTERMed (then SIGKILLed) it.
  def test_stale_pid_file_not_signalled
    victim = Process.spawn('sleep', '30', pgroup: true)
    File.write(pid_file, victim.to_s)
    status_out, = run_wayu('watch status')
    stop_out, stop_st = run_wayu('watch stop')
    sleep 0.2
    survived = alive?(victim)
    Process.kill('KILL', victim) rescue nil
    Process.wait(victim) rescue nil
    check('watch stop/status with a stale PID file: nothing signalled, PID file removed',
          survived && stop_st.success? && stop_out.include?('not running') &&
          status_out.include?('not running') && !File.exist?(pid_file),
          "survived=#{survived} stop=#{stop_st.exitstatus} out=#{status_out}#{stop_out}")
  end

  def test_start_status_stop
    env = ENV.to_h.merge('HOME' => @tmp_home)
    project_root = File.expand_path('../..', __dir__)
    watcher = Process.spawn(env, "#{@wayu_bin} watch", chdir: project_root,
                            out: File::NULL, err: File::NULL, in: File::NULL, pgroup: true)
    deadline = Time.now + 10
    sleep 0.05 until File.exist?(pid_file) || Time.now > deadline
    status_out, = run_wayu('watch status')
    second_out, second_st = run_wayu('watch start')
    stop_out, stop_st = run_wayu('watch stop')
    exited = begin
      Timeout.timeout(5) { Process.wait(watcher) }
      true
    rescue Timeout::Error
      Process.kill('KILL', -watcher) rescue nil
      Process.wait(watcher) rescue nil
      false
    end
    check('watch: status sees the watcher, a second start refuses, stop ends it',
          status_out.include?('is running') && second_st.success? &&
          second_out.include?('already running') && stop_st.success? &&
          stop_out.include?('stopped') && exited && !File.exist?(pid_file),
          "status=#{status_out} second=#{second_out} stop=#{stop_out} exited=#{exited}")
  end
end

if __FILE__ == $0
  WatchIntegrationTest.new.run
end
