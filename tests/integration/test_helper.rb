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
    @wayu_bin = File.expand_path('../../bin/wayu', __dir__)
    # Use /tmp directly (not Dir.mktmpdir which generates /var/folders paths on macOS)
    # The wayu binary reads HOME to construct $HOME/.config/wayu, so a short
    # predictable path avoids symlink resolution issues on macOS.
    @tmp_home   = "/tmp/wayu_test_#{$$}_#{rand(9999)}"
    @config_dir = "#{@tmp_home}/.config/wayu"
    # Pre-create ~/.config/ so the binary can create ~/.config/wayu inside it
    FileUtils.mkdir_p("#{@tmp_home}/.config")
  end

  # Call at the end of run (in ensure block so it always fires)
  def teardown_test_env
    FileUtils.rm_rf(@tmp_home) if @tmp_home && Dir.exist?(@tmp_home)
  end

  def build_project
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
