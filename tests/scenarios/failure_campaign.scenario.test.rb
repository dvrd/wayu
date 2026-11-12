#!/usr/bin/env ruby
# Real CLI/filesystem/process failures. Every case uses an isolated HOME.
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'timeout'
require 'digest'

class FailureCampaign
  def initialize
    @binary = File.expand_path(ENV.fetch('WAYU_BIN', 'bin/wayu'))
    raise "Build the candidate first: #{@binary}" unless File.executable?(@binary)
    @passed = []
  end

  def sandbox(label, data_parent: nil)
    home = Dir.mktmpdir("wayu-failure-#{label}-")
    begin
      data = data_parent ? Dir.mktmpdir('wayu-data-', data_parent) : "#{home}/data"
      cfg = "#{home}/config"
      FileUtils.mkdir_p([data, cfg])
      File.write("#{cfg}/wayu.toml", "[secrets]\nbackend = \"file\"\n")
      env = { 'HOME' => home, 'WAYU_CONFIG_DIR' => cfg, 'WAYU_DATA_DIR' => data,
              'PATH' => ENV.fetch('PATH'), 'SHELL' => '/bin/zsh', 'NO_COLOR' => '1',
              'TERM' => 'xterm-256color' }
      %w[ASAN_OPTIONS LSAN_OPTIONS UBSAN_OPTIONS].each { |k| env[k] = ENV[k] if ENV[k] }
      begin
        run!(env, 'init')
        run!(env, 'alias', 'add', 'anchor', 'echo intact')
        yield env, data, home
      ensure
        FileUtils.chmod(0700, data) if File.directory?(data)
        remove_fixture!(data) if data_parent
      end
    ensure
      remove_fixture!(home)
    end
    @passed << label
    puts "PASS failure campaign: #{label}"
  end

  def remove_fixture!(path)
    # An intentionally asynchronous zcompile can rename .tmp.zwc while
    # FileUtils walks the fixture. Force handles vanished entries; verify
    # the root really disappears and bound retries for newly created files.
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    loop do
      FileUtils.rm_rf(path)
      return unless File.exist?(path) || File.symlink?(path)
      raise "fixture cleanup did not finish: #{path}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.02
    end
  end

  def run!(env, *args)
    out, err, status = Open3.capture3(env, @binary, *args, unsetenv_others: true)
    raise "#{args.inspect}: #{status}\n#{err}" unless status.success?
    out
  end

  def entries(data)
    File.binread("#{data}/entries.json")
  end

  def assert_unchanged(data, before)
    raise 'entry store changed after failed operation' unless entries(data) == before
    raise 'anchor was lost' unless JSON.parse(before).fetch('aliases').any? { |a| a['name'] == 'anchor' }
  end

  def recover!(env)
    run!(env, 'alias', 'add', 'recovered', 'echo healthy')
    raise 'healthy mutation did not persist' unless run!(env, 'alias', 'get', 'recovered').strip == 'echo healthy'
  end

  def reported_write_failure!(status, err)
    # Entry persistence I/O errors use EXIT_IOERR. A usage error, sanitizer
    # exit or signal death must not count as a handled filesystem failure.
    raise "unexpected write-failure outcome: #{status}: #{err}" unless
      status.exited? && status.exitstatus == 74 && !err.empty?
  end

  def verify_full_disk_root!(root)
    # Refuse normal disks, ancestor mounts and large/shared tmpfs volumes.
    # This deliberately destructive fixture must be an owned, dedicated,
    # small Linux tmpfs created by the workflow, never a normal data dir.
    raise 'Real ENOSPC requires the isolated Linux tmpfs fixture' unless File.file?('/proc/self/mountinfo')
    real = File.realpath(root)
    raise 'Unexpected full-disk fixture name/owner' unless File.basename(real).start_with?('wayu-full-disk.') && File.stat(real).uid == Process.uid
    entry = File.readlines('/proc/self/mountinfo').find do |line|
      target = line.split[4].gsub(/\\([0-7]{3})/) { Regexp.last_match(1).to_i(8).chr }
      target == real
    end
    tail = entry && entry.split(' - ', 2)[1].split
    raise 'Full-disk fixture must be its own tmpfs mount' unless tail && tail[0] == 'tmpfs'
    size = tail[2].split(',').find { |v| v.start_with?('size=') }
    match = size && size.match(/\Asize=(\d+)([kmg]?)\z/i)
    bytes = match && match[1].to_i * { '' => 1, 'k' => 1024, 'm' => 1024**2, 'g' => 1024**3 }.fetch(match[2].downcase)
    raise 'Full-disk fixture must have an explicit size of at most 16 MiB' unless bytes && bytes > 0 && bytes <= 16 * 1024**2
  end

  def run
    # A small old store can be backed up; the larger replacement exceeds
    # the kernel's per-file limit during the atomic temp-file write.
    sandbox('partial-write-limit') do |env, data, _|
      before = entries(data)
      core_before = File.binread("#{data}/core.zsh")
      previous = Signal.trap('XFSZ', 'IGNORE')
      begin
        _, err, status = Open3.capture3(env, @binary, 'alias', 'add', 'too_big', 'x' * 8192,
                                       unsetenv_others: true, rlimit_fsize: [1024, 1024])
      ensure
        Signal.trap('XFSZ', previous)
      end
      reported_write_failure!(status, err)
      assert_unchanged(data, before)
      raise 'runtime changed after failed store write' unless File.binread("#{data}/core.zsh") == core_before
      raise 'atomic temp file leaked after handled failure' unless Dir.glob("#{data}/.entries.json.tmp.*").empty?
      recover!(env)
      # Positive control: the exact payload is valid without the resource
      # limit, so a validation rejection cannot make the fault test pass.
      run!(env, 'alias', 'add', 'too_big', 'x' * 8192)
      raise 'large payload failed without the limit' unless run!(env, 'alias', 'get', 'too_big').strip == 'x' * 8192
    end

    raise 'Permission denial cannot be tested as root' if Process.euid == 0
    sandbox('readonly-data-directory') do |env, data, _|
      before = entries(data)
      begin
        File.chmod(0500, data)
        _, err, status = Open3.capture3(env, @binary, 'alias', 'add', 'blocked', 'echo blocked', unsetenv_others: true)
        reported_write_failure!(status, err)
        assert_unchanged(data, before)
      ensure
        File.chmod(0700, data)
      end
      recover!(env)
    end

    sandbox('interrupted-lock-wait') do |env, data, home|
      before = entries(data)
      holder = "import fcntl,sys; f=open(sys.argv[1],'a+'); fcntl.lockf(f,fcntl.LOCK_EX); print('locked',flush=True); sys.stdin.read()"
      Open3.popen3(env, 'python3', '-u', '-c', holder, "#{data}/.wayu.lock", unsetenv_others: true) do |input, output, _, waiter|
        pid = nil
        begin
          raise 'lock holder failed to start' unless IO.select([output], nil, nil, 5) && output.gets == "locked\n"
          pid = Process.spawn(env, @binary, 'alias', 'add', 'blocked', 'echo blocked',
                              unsetenv_others: true, pgroup: true, out: "#{home}/blocked.log", err: [:child, :out])
          sleep 0.1
          raise 'mutation did not wait for lock' if Process.waitpid(pid, Process::WNOHANG)
          Process.kill('TERM', pid)
          _, status = Timeout.timeout(5) { Process.waitpid2(pid) }
          pid = nil
          raise 'interrupted mutation succeeded' if status.success?
          assert_unchanged(data, before)
        ensure
          if pid
            begin
              Process.kill('KILL', -pid)
              Process.waitpid(pid)
            rescue Errno::ESRCH, Errno::ECHILD
            end
          end
          input.close unless input.closed?
        end
        raise 'lock holder failed' unless waiter.value.success?
      end
      recover!(env)
    end

    sandbox('hard-termination-old-or-new') do |env, data, _|
      rng = Random.new(730_021)
      20.times do |n|
        pid = Process.spawn(env, @binary, 'alias', 'add', "crash_#{n}", 'x' * 8192,
                            unsetenv_others: true, pgroup: true, out: File::NULL, err: File::NULL)
        sleep(rng.rand * 0.004)
        begin
          Process.kill('KILL', pid)
        rescue Errno::ESRCH
        end
        _, status = Process.waitpid2(pid)
        raise "unexpected crash: #{status}" unless status.success? || status.termsig == Signal.list.fetch('KILL')
        doc = JSON.parse(entries(data))
        aliases = doc.fetch('aliases')
        raise 'anchor changed during termination' unless aliases.any? { |a| a['name'] == 'anchor' && a['value'] == 'echo intact' }
        aliases.each do |a|
          next unless a['name'].start_with?('crash_')
          raise 'partial entry became visible' unless a['value'] == 'x' * 8192
        end
      end
      recover!(env)
    end

    full_root = ENV['WAYU_FULL_DISK_ROOT']
    raise 'This run requires WAYU_FULL_DISK_ROOT on an isolated full-disk fixture' if ARGV.include?('--require-enospc') && !full_root
    if full_root
      raise 'Full-disk root must be a directory supplied by the isolated CI mount' unless File.directory?(full_root)
      verify_full_disk_root!(full_root)
      sandbox('real-enospc', data_parent: full_root) do |env, data, _|
        before = entries(data)
        filler = "#{data}/fill-space"
        begin
          File.open(filler, 'wb') { |f| 256.times { f.write('x' * 65_536) } }
          raise 'filesystem did not fill within the 16 MiB fixture bound'
        rescue Errno::ENOSPC
          # This is a real ENOSPC, distinct from the portable EFBIG case.
        end
        begin
          _, err, status = Open3.capture3(env, @binary, 'alias', 'add', 'blocked', 'echo blocked', unsetenv_others: true)
          reported_write_failure!(status, err)
          assert_unchanged(data, before)
        ensure
          FileUtils.rm_f(filler)
        end
        recover!(env)
      end
    else
      puts 'NOT RUN real ENOSPC: WAYU_FULL_DISK_ROOT not supplied (Linux CI supplies an isolated tmpfs)'
    end
    puts JSON.generate('binary_sha256' => Digest::SHA256.file(@binary).hexdigest,
                       'passed' => @passed, 'real_enospc' => !!full_root,
                       'kill_schedule' => '20 seeded delays; exact interrupted write phase is not controlled')
  end
end

FailureCampaign.new.run if __FILE__ == $0
