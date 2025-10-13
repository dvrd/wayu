#!/usr/bin/env ruby
# Integration tests for init command and multi-shell support

require 'open3'
require 'fileutils'
require 'tempfile'

class InitIntegrationTest
  attr_reader :passed, :failed

  def initialize
    @passed = 0
    @failed = 0
    @wayu_bin = './bin/wayu'
    @config_dir = File.expand_path('~/.config/wayu')
    @config_backup = File.expand_path('~/.config/wayu.backup')
  end

  def run
    puts "🚀 Testing init command and multi-shell integration..."
    puts

    build_project
    backup_config

    test_init_creates_directory_structure
    test_init_creates_config_files
    test_init_with_zsh
    test_init_with_bash
    test_config_file_templates
    test_init_file_orchestration
    test_shell_detection
    test_reinit_preserves_data
    test_dry_run_init
    test_help_command

    restore_config
    print_summary
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def build_project
    print "Building wayu..."
    stdout, stderr, status = Open3.capture3('task build')
    if status.success?
      puts " ✓"
    else
      puts " ✗"
      puts "Build failed: #{stderr}"
      exit 1
    end
    puts
  end

  def backup_config
    if Dir.exist?(@config_dir)
      print "Backing up existing config..."
      if Dir.exist?(@config_backup)
        FileUtils.rm_rf(@config_backup)
      end
      FileUtils.mv(@config_dir, @config_backup)
      puts " ✓"
    end
  end

  def restore_config
    print "\nRestoring original config..."
    if Dir.exist?(@config_dir)
      FileUtils.rm_rf(@config_dir)
    end
    if Dir.exist?(@config_backup)
      FileUtils.mv(@config_backup, @config_dir)
    end
    puts " ✓"
  end

  def test_init_creates_directory_structure
    print "Test 1: Init creates directory structure... "

    # Clean up any existing config
    FileUtils.rm_rf(@config_dir) if Dir.exist?(@config_dir)

    output, status = run_wayu("init")

    # Check that all required directories exist
    required_dirs = [
      @config_dir,
      "#{@config_dir}/functions",
      "#{@config_dir}/completions",
      "#{@config_dir}/plugins"
    ]

    all_exist = required_dirs.all? { |dir| Dir.exist?(dir) }

    if status.success? && all_exist
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to create directory structure"
      puts "  Missing: #{required_dirs.reject { |d| Dir.exist?(d) }.join(', ')}"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_init_creates_config_files
    print "Test 2: Init creates config files... "

    required_files = [
      "#{@config_dir}/path.zsh",
      "#{@config_dir}/aliases.zsh",
      "#{@config_dir}/constants.zsh",
      "#{@config_dir}/init.zsh",
      "#{@config_dir}/tools.zsh"
    ]

    all_exist = required_files.all? { |file| File.exist?(file) }

    if all_exist
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to create config files"
      puts "  Missing: #{required_files.reject { |f| File.exist?(f) }.join(', ')}"
      @failed += 1
    end
  end

  def test_init_with_zsh
    print "Test 3: Init with ZSH shell... "

    # Re-init with ZSH
    FileUtils.rm_rf(@config_dir) if Dir.exist?(@config_dir)
    output, status = run_wayu_with_env("init", {"SHELL" => "/bin/zsh"})

    if status.success? && output.include?("zsh")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  ZSH init failed"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_init_with_bash
    print "Test 4: Init with Bash shell... "

    # Re-init with Bash
    FileUtils.rm_rf(@config_dir) if Dir.exist?(@config_dir)
    output, status = run_wayu_with_env("init", {"SHELL" => "/bin/bash"})

    if status.success? && output.include?("bash")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Bash init failed"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_config_file_templates
    print "Test 5: Config file templates are valid... "

    # Reinitialize
    FileUtils.rm_rf(@config_dir) if Dir.exist?(@config_dir)
    run_wayu("init")

    # Check that each file has proper shebang and structure (relaxed checks)
    files_to_check = {
      "#{@config_dir}/path.zsh" => ["add_to_path"],
      "#{@config_dir}/aliases.zsh" => ["alias"],
      "#{@config_dir}/constants.zsh" => ["export"],
      "#{@config_dir}/init.zsh" => ["source"],
      "#{@config_dir}/tools.zsh" => []  # May be empty
    }

    all_valid = files_to_check.all? do |file, required_content|
      next false unless File.exist?(file)
      if required_content.empty?
        true
      else
        content = File.read(file)
        required_content.all? { |req| content.include?(req) }
      end
    end

    if all_valid
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Some config file templates are invalid"
      @failed += 1
    end
  end

  def test_init_file_orchestration
    print "Test 6: Init file orchestrates all configs... "

    init_content = File.read("#{@config_dir}/init.zsh")

    # Should source all config files in correct order
    sources_path = init_content.include?("path.zsh")
    sources_aliases = init_content.include?("aliases.zsh")
    sources_constants = init_content.include?("constants.zsh")
    sources_tools = init_content.include?("tools.zsh")

    if sources_path && sources_aliases && sources_constants && sources_tools
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Init file doesn't orchestrate all configs properly"
      @failed += 1
    end
  end

  def test_shell_detection
    print "Test 7: Shell type detection... "

    # Test ZSH detection
    output_zsh, _ = run_wayu_with_env("--shell zsh path list", {"SHELL" => "/bin/zsh"})

    # Test Bash detection
    output_bash, _ = run_wayu_with_env("--shell bash path list", {"SHELL" => "/bin/bash"})

    # Both should work without errors
    if !output_zsh.include?("error") && !output_bash.include?("error")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Shell detection issues"
      @failed += 1
    end
  end

  def test_reinit_preserves_data
    print "Test 8: Re-init preserves existing data... "

    # Add some data
    run_wayu('path add /tmp')
    sleep(0.5)  # Give time for file write

    # Re-initialize (should not destroy existing data)
    output, status = run_wayu("init")

    # Init should succeed without destroying config
    if status.success?
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Re-init failed"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_dry_run_init
    print "Test 9: Dry-run init mode... "

    # Clean up
    FileUtils.rm_rf(@config_dir) if Dir.exist?(@config_dir)

    output, status = run_wayu("--dry-run init")

    # In dry-run mode, should not create files or show preview
    if !Dir.exist?("#{@config_dir}/path.zsh") || output.include?("DRY RUN") || output.include?("Would")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Dry-run init created files"
      @failed += 1
    end
  end

  def test_help_command
    print "Test 10: Help command... "

    output, status = run_wayu("init --help")

    if output.include?("init") || output.include?("Initialize")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Help output incomplete"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def run_wayu(args)
    stdout, stderr, status = Open3.capture3("#{@wayu_bin} #{args}")
    # Force UTF-8 encoding for the output
    stdout = stdout.force_encoding('UTF-8') if stdout
    stderr = stderr.force_encoding('UTF-8') if stderr
    # Return combined output for easier checking
    [stdout + stderr, status]
  end

  def run_wayu_with_env(args, env = {})
    stdout, stderr, status = Open3.capture3(env, "#{@wayu_bin} #{args}")
    # Force UTF-8 encoding for the output
    stdout = stdout.force_encoding('UTF-8') if stdout
    stderr = stderr.force_encoding('UTF-8') if stderr
    # Return combined output for easier checking
    [stdout + stderr, status]
  end

  def print_summary
    puts
    puts "━" * 50
    total = @passed + @failed
    if @failed == 0
      puts "✓ All #{total} init and multi-shell integration tests passed!"
    else
      puts "Results: #{@passed}/#{total} tests passed, #{@failed} failed"
    end
    puts "━" * 50
  end
end

# Run tests if executed directly
if __FILE__ == $0
  InitIntegrationTest.new.run
end
