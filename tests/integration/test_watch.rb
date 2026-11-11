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
      test_stop_never_signals_non_holder
      test_pid_file_symlink_not_followed
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

  # The lock is held (here by a stand-in holding an fcntl lock, like a
  # momentary `watch status` of an older wayu) but the PID file names
  # another process: stop must signal nobody.
  def test_stop_never_signals_non_holder
    victim = Process.spawn('sleep', '30', pgroup: true)
    File.write(pid_file, victim.to_s)
    lock = "#{@data_dir}/watcher.lock"
    holder_code = "import fcntl,sys,time\nf=open(sys.argv[1],'a+')\nfcntl.lockf(f,fcntl.LOCK_EX)\nprint('locked',flush=True)\ntime.sleep(30)\n"
    rd, wr = IO.pipe
    holder = Process.spawn('python3', '-c', holder_code, lock, out: wr, pgroup: true)
    wr.close
    Timeout.timeout(5) { rd.gets }
    stop_out, stop_st = run_wayu('watch stop')
    sleep 0.2
    survived = alive?(victim) && alive?(holder)
    [victim, holder].each { |p| Process.kill('KILL', p) rescue nil; Process.wait(p) rescue nil }
    FileUtils.rm_f(pid_file)
    check('watch stop: lock holder differs from the PID file -> nothing signalled, exit 1',
          survived && stop_st.exitstatus == 1 && stop_out.include?('not signalling'),
          "survived=#{survived} stop=#{stop_st.exitstatus} out=#{stop_out}")
  rescue Timeout::Error
    check('watch stop: lock holder differs from the PID file', false, 'lock holder did not start')
  end

  # The PID file is replaced atomically (0600), never written through a
  # symlink planted at its path.
  def test_pid_file_symlink_not_followed
    outside = "#{@tmp_home}/outside-pid-target"
    File.write(outside, "keep\n")
    FileUtils.rm_f(pid_file)
    File.symlink(outside, pid_file)
    env = ENV.to_h.merge('HOME' => @tmp_home)
    watcher = Process.spawn(env, "#{@wayu_bin} watch", out: File::NULL, err: File::NULL,
                            in: File::NULL, pgroup: true)
    deadline = Time.now + 10
    sleep 0.05 until (File.file?(pid_file) && !File.symlink?(pid_file)) || Time.now > deadline
    replaced = File.file?(pid_file) && !File.symlink?(pid_file)
    mode = replaced ? File.stat(pid_file).mode & 0o777 : 0
    run_wayu('watch stop')
    Timeout.timeout(5) { Process.wait(watcher) } rescue (Process.kill('KILL', -watcher) rescue nil)
    check('watch: PID file written 0600 by rename, symlink target untouched',
          replaced && mode == 0o600 && File.read(outside) == "keep\n",
          "replaced=#{replaced} mode=#{mode.to_s(8)} outside=#{File.read(outside).inspect}")
  end
end

if __FILE__ == $0
  WatchIntegrationTest.new.run
end
