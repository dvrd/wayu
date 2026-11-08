# Shared test infrastructure for wayu integration tests
#
# Uses a temporary HOME directory so tests NEVER touch ~/.config/wayu.
# The wayu binary reads HOME from the environment and constructs
# $HOME/.config/wayu — so setting HOME=/tmp/wayu_test_XXXX is enough.

require 'open3'
require 'fileutils'
require 'tmpdir'

module WayuTestHelper
  def self.included(base)
    base.instance_eval do
      attr_reader :passed, :failed
    end
  end

  # Call once in initialize
  def setup_test_env
    @passed = 0
    @failed = 0
    # WAYU_BIN runs the suite against another build (e.g. the CI
    # AddressSanitizer job); build_project then leaves it alone.
    @wayu_bin = File.expand_path(ENV['WAYU_BIN'] || '../../bin/wayu', ENV['WAYU_BIN'] ? Dir.pwd : __dir__)
    # Hermetic default shell: wayu picks file extensions from $SHELL, and CI
    # runners default to bash. Tests that need another shell pass SHELL or
    # --shell explicitly (those override this).
    ENV['SHELL'] = '/bin/zsh'
    # Under /tmp explicitly (mktmpdir's default is /var/folders/... on macOS):
    # the binary builds $HOME/.config/wayu from HOME, and a short path avoids
    # symlink-resolution surprises. Unique per run, so concurrent runs never
    # share a HOME.
    @tmp_home   = Dir.mktmpdir('wayu_test_', '/tmp')
    # Scratch dirs a test creates on disk (e.g. directories to `path add`).
    # Outside HOME, so wayu doesn't rewrite them to $HOME/...; per run, so
    # concurrent runs never add/remove each other's directories. Short
    # prefix: list tables truncate long paths.
    @scratch    = Dir.mktmpdir('ws', '/tmp')
    # Suites exit from the middle of a run (exit/abort on a failed setup);
    # remove the temp dirs whatever path ends the process.
    at_exit { teardown_test_env }
    @config_dir = "#{@tmp_home}/.config/wayu"
    @data_dir   = "#{@tmp_home}/.config/wayu"
    # Pre-create parent dirs so the binary can create config/data inside
    FileUtils.mkdir_p("#{@tmp_home}/.config")
    FileUtils.mkdir_p("#{@tmp_home}/.local/share")
  end

  # Call at the end of run (in ensure block so it always fires)
  def teardown_test_env
    FileUtils.rm_rf(@tmp_home) if @tmp_home && Dir.exist?(@tmp_home)
    FileUtils.rm_rf(@scratch) if @scratch && Dir.exist?(@scratch)
  end

  def build_project
    return if ENV['WAYU_BIN']
    print "Building wayu..."
    project_root = File.expand_path('../..', __dir__)
    stdout, stderr, status = Open3.capture3('./build_it build', chdir: project_root)
    if status.success?
      puts " ✓"
    else
      puts " ✗"
      puts "Build failed: #{stderr}"
      exit 1
    end
    puts
  end

  def initialize_wayu(shell: 'zsh')
    print "Initializing wayu config..."
    output, status = run_wayu("init --shell #{shell}")
    if status.success?
      puts " ✓"
    else
      puts " ✗"
      puts "Init failed: #{output}"
      teardown_test_env
      exit 1
    end
    puts
  end

  # Sanitizer settings to keep when a test clears the environment
  # (unsetenv_others), so an ASan build keeps the CI job's ASAN_OPTIONS.
  def sanitizer_env
    ENV.to_h.select { |k, _| %w[ASAN_OPTIONS LSAN_OPTIONS UBSAN_OPTIONS].include?(k) }
  end

  def run_wayu(args)
    # Merge HOME override into the current environment so PATH and other
    # variables are preserved. Open3 with an env hash replaces the env
    # entirely, so we must start from ENV and override only HOME.
    env = ENV.to_h.merge('HOME' => @tmp_home)
    project_root = File.expand_path('../..', __dir__)
    stdout, stderr, status = Open3.capture3(env, "#{@wayu_bin} #{args}", chdir: project_root)
    stdout = stdout.force_encoding('UTF-8')
    stderr = stderr.force_encoding('UTF-8')
    [stdout + stderr, status]
  end

  # Run `wayu args` while another process holds the config lock
  # (<config>/.wayu.lock, POSIX record lock) for `hold` seconds. Returns
  # [output, status, seconds_waited], or nil when python3 is unavailable
  # (Ruby's File#flock is a different lock on macOS).
  def run_wayu_with_config_lock_held(args, hold: 2)
    py = `command -v python3 2>/dev/null`.strip
    return nil if py.empty?
    holder = IO.popen([py, '-I', '-c',
      'import fcntl, sys, time; f = open(sys.argv[1], "a+"); fcntl.lockf(f, fcntl.LOCK_EX); ' \
      'print("locked", flush=True); time.sleep(float(sys.argv[2]))',
      "#{@config_dir}/.wayu.lock", hold.to_s])
    holder.gets # returns once the lock is held
    t0 = Time.now
    out, status = run_wayu(args)
    waited = Time.now - t0
    holder.close
    [out, status, waited]
  end

  def print_summary(label)
    puts
    puts "━" * 50
    total = @passed + @failed
    if @failed == 0
      puts "✓ All #{total} #{label} integration tests passed!"
    else
      puts "Results: #{@passed}/#{total} tests passed, #{@failed} failed"
    end
    puts "━" * 50
  end
end
