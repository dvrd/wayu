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
      test_retention_after_many_writes
      test_restore_chosen_backup
      test_restore_waits_for_config_lock
    ensure
      cleanup
      teardown_test_env
    end

    print_summary("backup")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def report(label, ok, detail)
    print "#{label}... "
    if ok
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  #{detail}"
      @failed += 1
    end
  end

  # OKAMI-232: every alias/const/path write prunes to the last 5 backups.
  def test_retention_after_many_writes
    12.times { |i| run_wayu("alias add ret#{i} 'echo #{i}'") }
    5.times { |i| run_wayu("const add RET_#{i} v#{i}") }
    n = Dir.glob("#{@data_dir}/backup/entries.json.backup.*").size
    report("Test 9: 17 writes keep exactly 5 backups", n == 5, "found #{n}")
    12.times { |i| run_wayu("alias rm ret#{i}") }
    5.times { |i| run_wayu("const rm RET_#{i}") }
  end

  # OKAMI-232: `backup restore <type> N` picks a backup; the default restore
  # is idempotent (no ping-pong between the last two states).
  def test_restore_chosen_backup
    toml = @entries_file
    run_wayu("alias add pick1 one")
    run_wayu("alias add pick2 two")
    run_wayu("alias add pick3 three")   # newest backup: pick1+pick2
    run_wayu("backup restore alias --yes")
    first = File.read(toml)
    run_wayu("backup restore alias --yes")
    second = File.read(toml)
    no_ping_pong = first.include?("pick2") && !first.include?("pick3") && first == second

    # list: [pre-restore], [pre-restore], pick1+pick2, pick1, (older)
    out, st = run_wayu("backup restore alias 4 --yes")
    chose_older = st.success? && File.read(toml).include?("pick1") && !File.read(toml).include?("pick2")
    _o2, bad = run_wayu("backup restore alias 99 --yes")
    listed = run_wayu("backup list alias")[0].include?("pre-restore")
    report("Test 10: restore picks a backup by index, default does not ping-pong",
           no_ping_pong && chose_older && bad.exitstatus == 65 && listed,
           "no_ping_pong=#{no_ping_pong} chose_older=#{chose_older} bad=#{bad.exitstatus} listed=#{listed} out=#{out[0, 300]}")
    %w[pick1 pick2 pick3].each { |a| run_wayu("alias rm #{a}") }
  end

  # A restore is an entries.json write: without the config lock a concurrent
  # `alias add` that read the file earlier overwrote the restore.
  def test_restore_waits_for_config_lock
    run_wayu("alias add lockt one")
    out, st, waited = run_wayu_with_config_lock_held("backup restore alias --yes", hold: 2)
    if waited.nil?
      report("Test 11: restore waits for the config lock (skipped: no python3)", true, "")
    else
      report("Test 11: restore waits for the config lock", st.success? && waited >= 1.5,
             "waited=#{waited.round(2)}s exit=#{st.exitstatus} #{out[0, 200]}")
    end
    run_wayu("alias rm lockt")
  end

  def test_automatic_backup_creation
    print "Test 1: Automatic backup creation... "

    # Clear any existing backups
    backup_files = Dir.glob("#{@data_dir}/backup/*.backup.*")
    backup_files.each { |f| File.delete(f) }

    # Create test directory
    test_dir = "#{@scratch}/test1"
    Dir.mkdir(test_dir) unless Dir.exist?(test_dir)

    # The first write creates entries.json (nothing to back up yet); the
    # second backs up the first.
    run_wayu("alias add backup_seed ls")
    output, status = run_wayu("path add #{test_dir}")

    if status.success?
      # Check if backup was created
      backup_files = Dir.glob("#{@data_dir}/backup/entries.json.backup.*")
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
    ["#{@scratch}/test2", "#{@scratch}/test3"].each do |dir|
      Dir.mkdir(dir) unless Dir.exist?(dir)
    end
    run_wayu("path add #{@scratch}/test2")
    run_wayu("path add #{@scratch}/test3")

    output, status = run_wayu("backup list")

    if output.include?("Configuration Backups") && output.include?("entries.json")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected backup list with entries.json"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_backup_list_specific_config
    print "Test 4: List backups for specific config type... "

    output, status = run_wayu("backup list path")

    if output.include?("Backups for entries.json")
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
    ["#{@scratch}/original", "#{@scratch}/modified"].each do |dir|
      Dir.mkdir(dir) unless Dir.exist?(dir)
    end

    # Add initial path
    run_wayu("path add #{@scratch}/original")

    # Modify by adding another path
    run_wayu("path add #{@scratch}/modified")

    # Verify the modification exists
    toml_content = File.read(@entries_file) rescue ""

    if toml_content.include?("#{@scratch}/modified")
      backups_before = Dir.glob("#{@data_dir}/backup/entries.json.backup.*").size

      # Restore from backup (destructive: requires --yes)
      output, status = run_wayu("backup restore path --yes")

      restored_content = File.read(@entries_file) rescue ""
      reverted = !restored_content.include?("#{@scratch}/modified") &&
                 restored_content.include?("#{@scratch}/original")
      # The pre-restore state must itself have been backed up (undoable).
      backups_after = Dir.glob("#{@data_dir}/backup/entries.json.backup.*").size
      pre_restore_backed_up = backups_after == backups_before + 1
      whole_file_note = output.include?("reverts all of them")
      # Generated shell init must reflect the restored config.
      core = File.read("#{@data_dir}/core.zsh") rescue ""
      regenerated = !core.include?("#{@scratch}/modified")

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
    before = File.read(@entries_file)
    output, status = run_wayu("backup restore path")
    after = File.read(@entries_file)
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
    print "Test 5c: Backup restore refuses an invalid entries.json backup... "
    before = File.read(@entries_file)
    # Plant a newest-looking corrupt backup.
    corrupt = "#{@data_dir}/backup/entries.json.backup.2200-01-01_00-00-00.000000"
    File.write(corrupt, %({"version": 1, "paths": [\n))
    output, status = run_wayu("backup restore path --yes")
    after = File.read(@entries_file)
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
    FileUtils.mkdir_p("#{@scratch}/wayu_rapid_a")
    FileUtils.mkdir_p("#{@scratch}/wayu_rapid_b")
    FileUtils.mkdir_p("#{@scratch}/wayu_rapid_c")
    pristine = File.read(@entries_file)
    before = Dir.glob("#{@data_dir}/backup/entries.json.backup.*").size
    # Three writes well within one second.
    run_wayu("path add #{@scratch}/wayu_rapid_a")
    run_wayu("path add #{@scratch}/wayu_rapid_b")
    run_wayu("path add #{@scratch}/wayu_rapid_c")
    files = Dir.glob("#{@data_dir}/backup/entries.json.backup.*")
    pristine_kept = files.any? { |f| File.read(f) == pristine }
    # Retention caps the count at 5 (OKAMI-232).
    if files.size == [before + 3, 5].min && pristine_kept
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  before=#{before} after=#{files.size} pristine_kept=#{pristine_kept}"
      @failed += 1
    end
  ensure
    %w[a b c].each { |s| FileUtils.rm_rf("#{@scratch}/wayu_rapid_#{s}") }
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

    # Every write already prunes to 5, so seed 8 backups by hand (distinct
    # stamps, oldest first) to give `backup rm` something to remove.
    FileUtils.mkdir_p("#{@data_dir}/backup")
    stamps = (1..8).map { |i| format('2020-01-%02d_00-00-00.000000', i) }
    stamps.each { |s| File.write("#{@data_dir}/backup/entries.json.backup.#{s}", "{}\n") }
    backup_files_before = Dir.glob("#{@data_dir}/backup/entries.json.backup.*")

    # Run cleanup (destructive: requires --yes)
    output, status = run_wayu("backup rm --yes")

    if status.success?
      backup_files_after = Dir.glob("#{@data_dir}/backup/entries.json.backup.*")

      # Keeps the newest 5: the 3 oldest seeded ones go, newer ones stay.
      gone = stamps.first(3).none? { |s| File.exist?("#{@data_dir}/backup/entries.json.backup.#{s}") }
      if backup_files_before.length > 5 && backup_files_after.length == 5 && gone
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

    if status.exitstatus == 65 && output.include?("Unknown config type: invalid_type")
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
    test_dirs = ["#{@scratch}/test1", "#{@scratch}/test2", "#{@scratch}/test3", "#{@scratch}/original", "#{@scratch}/modified"] +
                (0..4).map { |i| "#{@scratch}/cleanup_test_#{i}" }

    test_dirs.each do |dir|
      FileUtils.rm_rf(dir) if Dir.exist?(dir)
    end
  end

end

# Run tests if executed directly
if __FILE__ == $0
  BackupIntegrationTest.new.run
end
