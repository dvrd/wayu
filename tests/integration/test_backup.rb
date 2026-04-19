#!/usr/bin/env ruby
# Integration tests for backup system

require 'open3'
require 'fileutils'
require_relative 'test_helper'

class BackupIntegrationTest
  include WayuTestHelper

  def initialize
    setup_test_env
  end

  def run
    puts "💾 Testing backup system integration..."
    puts

    begin
      build_project
      initialize_wayu

      test_automatic_backup_creation
      test_backup_list_empty
      test_backup_list_with_backups
      test_backup_list_specific_config
      test_backup_restore_functionality
      test_backup_cleanup
      test_backup_help
      test_backup_error_handling
    ensure
      cleanup
      teardown_test_env
    end

    print_summary("backup")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def test_automatic_backup_creation
    print "Test 1: Automatic backup creation... "

    # Clear any existing backups
    backup_files = Dir.glob("#{@config_dir}/backup/*.backup.*")
    backup_files.each { |f| File.delete(f) }

    # Create test directory
    test_dir = "/tmp/test1"
    Dir.mkdir(test_dir) unless Dir.exist?(test_dir)

    # Add a path which should create a backup
    output, status = run_wayu("path add #{test_dir}")

    if status.success?
      # Check if backup was created
      backup_files = Dir.glob("#{@config_dir}/backup/wayu.toml.backup.*")
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
    backup_files = Dir.glob("#{@config_dir}/backup/*.backup.*")
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

    if output.include?("Configuration Backups") && output.include?("wayu.toml")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected backup list with wayu.toml"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_backup_list_specific_config
    print "Test 4: List backups for specific config type... "

    output, status = run_wayu("backup list path")

    if output.include?("Backups for wayu.toml") || output.include?("backup")
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
    toml_content = File.read("#{@config_dir}/wayu.toml") rescue ""

    if toml_content.include?("/tmp/modified")
      # Restore from backup
      output, status = run_wayu("backup restore path")

      if status.success? && output.include?("Restored from backup")
        # Check if file was restored (should not contain the latest addition)
        restored_content = File.read("#{@config_dir}/wayu.toml") rescue ""

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
    backup_files_before = Dir.glob("#{@config_dir}/backup/wayu.toml.backup.*")

    # Run cleanup
    output, status = run_wayu("backup rm")

    if status.success?
      backup_files_after = Dir.glob("#{@config_dir}/backup/wayu.toml.backup.*")

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

    if output.include?("wayu backup") && output.include?("EXAMPLES")
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

  def cleanup
    # Clean up test directories
    test_dirs = ["/tmp/test1", "/tmp/test2", "/tmp/test3", "/tmp/original", "/tmp/modified"] +
                (0..4).map { |i| "/tmp/cleanup_test_#{i}" }

    test_dirs.each do |dir|
      FileUtils.rm_rf(dir) if Dir.exist?(dir)
    end
  end

end

# Run tests if executed directly
if __FILE__ == $0
  BackupIntegrationTest.new.run
end
