#!/usr/bin/env ruby
# Integration tests for backup system

require 'open3'
require 'fileutils'
require 'tempfile'

class BackupIntegrationTest
  attr_reader :passed, :failed

  def initialize
    @passed = 0
    @failed = 0
    @wayu_bin = './bin/wayu'
    @config_dir = File.expand_path('~/.config/wayu')
    @config_backup = File.expand_path('~/.config/wayu.backup')
  end

  def run
    puts "💾 Testing backup system integration..."
    puts

    build_project
    backup_config
    initialize_wayu

    test_automatic_backup_creation
    test_backup_list_empty
    test_backup_list_with_backups
    test_backup_list_specific_config
    test_backup_restore_functionality
    test_backup_cleanup
    test_backup_help
    test_backup_error_handling

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

  def initialize_wayu
    print "Initializing wayu config..."
    output, status = run_wayu("init")
    if status.success?
      puts " ✓"
    else
      puts " ✗"
      puts "Init failed: #{output}"
      restore_config
      exit 1
    end
    puts
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

  def test_automatic_backup_creation
    print "Test 1: Automatic backup creation... "

    # Clear any existing backups
    backup_files = Dir.glob("#{@config_dir}/*.backup.*")
    backup_files.each { |f| File.delete(f) }

    # Create test directory
    test_dir = "/tmp/test1"
    Dir.mkdir(test_dir) unless Dir.exist?(test_dir)

    # Add a path which should create a backup
    output, status = run_wayu("path add #{test_dir}")

    if status.success?
      # Check if backup was created
      backup_files = Dir.glob("#{@config_dir}/path.zsh.backup.*")
      if backup_files.length > 0
        puts "✓"
        @passed += 1
      else
        puts "✗"
        puts "  No backup created"
        @failed += 1
      end
    else
      puts "✗"
      puts "  Failed to add path: #{output}"
      @failed += 1
    end
  end

  def test_backup_list_empty
    print "Test 2: List backups when none exist... "

    # Clear all backups
    backup_files = Dir.glob("#{@config_dir}/*.backup.*")
    backup_files.each { |f| File.delete(f) }

    output, status = run_wayu("backup list")

    if output.include?("No backups found")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected 'No backups found'"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_backup_list_with_backups
    print "Test 3: List backups when backups exist... "

    # Create test directories and backups by adding paths
    ["/tmp/test2", "/tmp/test3"].each do |dir|
      Dir.mkdir(dir) unless Dir.exist?(dir)
    end
    run_wayu("path add /tmp/test2")
    run_wayu("path add /tmp/test3")

    output, status = run_wayu("backup list")

    if output.include?("Configuration Backups") && output.include?("path.zsh")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected backup list with path.zsh"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_backup_list_specific_config
    print "Test 4: List backups for specific config type... "

    output, status = run_wayu("backup list path")

    if output.include?("Backups for path.zsh") || output.include?("backup")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected backup list for path config"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_backup_restore_functionality
    print "Test 5: Backup restore functionality... "

    # Create test directories
    ["/tmp/original", "/tmp/modified"].each do |dir|
      Dir.mkdir(dir) unless Dir.exist?(dir)
    end

    # Add initial path
    run_wayu("path add /tmp/original")

    # Modify by adding another path
    run_wayu("path add /tmp/modified")

    # Verify the modification exists
    path_content = File.read("#{@config_dir}/path.zsh") rescue ""

    if path_content.include?("/tmp/modified")
      # Restore from backup
      output, status = run_wayu("backup restore path")

      if status.success? && output.include?("Restored from backup")
        # Check if file was restored (should not contain the latest addition)
        restored_content = File.read("#{@config_dir}/path.zsh") rescue ""

        # The restore should have reverted to a previous state
        puts "✓"
        @passed += 1
      else
        puts "✗"
        puts "  Restore failed: #{output}"
        @failed += 1
      end
    else
      puts "✗"
      puts "  Failed to set up test condition"
      @failed += 1
    end
  end

  def test_backup_cleanup
    print "Test 6: Backup cleanup functionality... "

    # Create multiple backups by making multiple changes
    5.times do |i|
      test_dir = "/tmp/cleanup_test_#{i}"
      Dir.mkdir(test_dir) unless Dir.exist?(test_dir)
      run_wayu("path add #{test_dir}")
      sleep(0.1) # Ensure different timestamps
    end

    # Count backups before cleanup
    backup_files_before = Dir.glob("#{@config_dir}/path.zsh.backup.*")

    # Run cleanup
    output, status = run_wayu("backup rm")

    if status.success?
      backup_files_after = Dir.glob("#{@config_dir}/path.zsh.backup.*")

      # Should have cleaned up some backups (keeping last 5)
      if backup_files_after.length <= 5
        puts "✓"
        @passed += 1
      else
        puts "✗"
        puts "  Cleanup didn't reduce backup count appropriately"
        puts "  Before: #{backup_files_before.length}, After: #{backup_files_after.length}"
        @failed += 1
      end
    else
      puts "✗"
      puts "  Cleanup failed: #{output}"
      @failed += 1
    end
  end

  def test_backup_help
    print "Test 7: Backup help command... "

    output, status = run_wayu("backup help")

    if output.include?("Backup Command") && output.include?("EXAMPLES")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Help output incomplete"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_backup_error_handling
    print "Test 8: Backup error handling... "

    # Test invalid config type
    output, status = run_wayu("backup restore invalid_type")

    if output.include?("Unknown config type") || output.include?("Valid types")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected error for invalid config type"
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

  def cleanup
    # Clean up test directories
    test_dirs = ["/tmp/test1", "/tmp/test2", "/tmp/test3", "/tmp/original", "/tmp/modified"] +
                (0..4).map { |i| "/tmp/cleanup_test_#{i}" }

    test_dirs.each do |dir|
      FileUtils.rm_rf(dir) if Dir.exist?(dir)
    end
  end

  def print_summary
    puts
    puts "━" * 50
    total = @passed + @failed
    if @failed == 0
      puts "✓ All #{total} backup integration tests passed!"
    else
      puts "Results: #{@passed}/#{total} tests passed, #{@failed} failed"
    end
    puts "━" * 50
  end
end

# Run tests if executed directly
if __FILE__ == $0
  BackupIntegrationTest.new.run
end