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
      test_backup_restore_requires_yes
      test_backup_restore_rejects_corrupt_backup
      test_rapid_backups_do_not_overwrite
      test_backup_list_json_escapes_paths
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
    backup_files = Dir.glob("#{@data_dir}/backup/*.backup.*")
    backup_files.each { |f| File.delete(f) }

    # Create test directory
    test_dir = "/tmp/test1"
    Dir.mkdir(test_dir) unless Dir.exist?(test_dir)

    # Add a path which should create a backup
    output, status = run_wayu("path add #{test_dir}")

    if status.success?
      # Check if backup was created
      backup_files = Dir.glob("#{@data_dir}/backup/wayu.toml.backup.*")
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
    backup_files = Dir.glob("#{@data_dir}/backup/*.backup.*")
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
      backups_before = Dir.glob("#{@data_dir}/backup/wayu.toml.backup.*").size

      # Restore from backup (destructive: requires --yes)
      output, status = run_wayu("backup restore path --yes")

      restored_content = File.read("#{@config_dir}/wayu.toml") rescue ""
      reverted = !restored_content.include?("/tmp/modified") &&
                 restored_content.include?("/tmp/original")
      # The pre-restore state must itself have been backed up (undoable).
      backups_after = Dir.glob("#{@data_dir}/backup/wayu.toml.backup.*").size
      pre_restore_backed_up = backups_after == backups_before + 1
      whole_file_note = output.include?("entire file")
      # Generated shell init must reflect the restored config.
      core = File.read("#{@data_dir}/core.zsh") rescue ""
      regenerated = !core.include?("/tmp/modified")

      if status.success? && output.include?("Restored from backup") && reverted &&
         pre_restore_backed_up && whole_file_note && regenerated
        puts "✓"
        @passed += 1
      else
        puts "✗"
        puts "  ok=#{status.success?} reverted=#{reverted} pre_backup=#{pre_restore_backed_up} note=#{whole_file_note} regen=#{regenerated}"
        puts "  Output: #{output}"
        @failed += 1
      end
    else
      puts "✗"
      puts "  Failed to set up test condition"
      @failed += 1
    end
  end

  def test_backup_restore_requires_yes
    print "Test 5b: Backup restore without --yes is refused (exit 64)... "
    run_wayu("path add /tmp")
    before = File.read("#{@config_dir}/wayu.toml")
    output, status = run_wayu("backup restore path")
    after = File.read("#{@config_dir}/wayu.toml")
    if status.exitstatus == 64 && before == after && output.include?("--yes")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  exit=#{status.exitstatus} unchanged=#{before == after}"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_backup_restore_rejects_corrupt_backup
    print "Test 5c: Backup restore refuses an invalid TOML backup... "
    before = File.read("#{@config_dir}/wayu.toml")
    # Plant a newest-looking corrupt backup.
    corrupt = "#{@data_dir}/backup/wayu.toml.backup.2200-01-01_00-00-00.000000"
    File.write(corrupt, "[paths\nthis is = = not toml\n")
    output, status = run_wayu("backup restore path --yes")
    after = File.read("#{@config_dir}/wayu.toml")
    File.delete(corrupt) if File.exist?(corrupt)
    if !status.success? && before == after
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  exit=#{status.exitstatus} unchanged=#{before == after}"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_rapid_backups_do_not_overwrite
    print "Test 5d: Back-to-back writes each keep their own backup... "
    FileUtils.mkdir_p("/tmp/wayu_rapid_a")
    FileUtils.mkdir_p("/tmp/wayu_rapid_b")
    FileUtils.mkdir_p("/tmp/wayu_rapid_c")
    pristine = File.read("#{@config_dir}/wayu.toml")
    before = Dir.glob("#{@data_dir}/backup/wayu.toml.backup.*").size
    # Three writes well within one second.
    run_wayu("path add /tmp/wayu_rapid_a")
    run_wayu("path add /tmp/wayu_rapid_b")
    run_wayu("path add /tmp/wayu_rapid_c")
    files = Dir.glob("#{@data_dir}/backup/wayu.toml.backup.*")
    pristine_kept = files.any? { |f| File.read(f) == pristine }
    if files.size == before + 3 && pristine_kept
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  before=#{before} after=#{files.size} pristine_kept=#{pristine_kept}"
      @failed += 1
    end
  ensure
    %w[a b c].each { |s| FileUtils.rm_rf("/tmp/wayu_rapid_#{s}") }
  end

  def test_backup_list_json_escapes_paths
    print "Test 5e: backup list --json emits valid JSON... "
    output, status = run_wayu("--json backup list")
    begin
      require 'json'
      JSON.parse(output)
      puts "✓"
      @passed += 1
    rescue JSON::ParserError => e
      puts "✗"
      puts "  #{e.message[0..200]}"
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
    backup_files_before = Dir.glob("#{@data_dir}/backup/wayu.toml.backup.*")

    # Run cleanup (destructive: requires --yes)
    output, status = run_wayu("backup rm --yes")

    if status.success?
      backup_files_after = Dir.glob("#{@data_dir}/backup/wayu.toml.backup.*")

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
