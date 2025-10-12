#!/usr/bin/env ruby
# Integration tests for dry-run mode

require 'open3'
require 'fileutils'

class DryRunIntegrationTest
  attr_reader :passed, :failed

  def initialize
    @passed = 0
    @failed = 0
    @wayu_bin = './bin/wayu'
    @config_dir = File.expand_path('~/.config/wayu')
    @config_backup = File.expand_path('~/.config/wayu.backup')
  end

  def run
    puts "🧪 Testing dry-run mode integration..."
    puts

    build_project
    backup_config
    initialize_wayu

    test_path_dry_run_add
    test_path_dry_run_remove
    test_alias_dry_run_add
    test_constants_dry_run_add
    test_backup_dry_run_restore
    test_dry_run_no_file_changes

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

  def test_path_dry_run_add
    print "Test 1: PATH add dry-run mode... "

    output, status = run_wayu("--dry-run path add /tmp")

    if status.success? && output.include?("DRY RUN") && output.include?("Would add to path.zsh")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected dry-run output for path add"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_path_dry_run_remove
    print "Test 2: PATH remove dry-run mode... "

    output, status = run_wayu("-n path rm /nonexistent")

    if output.include?("DRY RUN") && output.include?("Would remove from path.zsh")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected dry-run output for path remove"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_alias_dry_run_add
    print "Test 3: Alias add dry-run mode... "

    output, status = run_wayu("--dry-run alias add gc 'git commit'")

    if status.success? && output.include?("DRY RUN") && output.include?("Would add to aliases.zsh")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected dry-run output for alias add"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_constants_dry_run_add
    print "Test 4: Constants add dry-run mode... "

    output, status = run_wayu("-n constants add MY_VAR 'test value'")

    if status.success? && output.include?("DRY RUN") && output.include?("Would add to constants.zsh")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected dry-run output for constants add"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_backup_dry_run_restore
    print "Test 5: Backup restore dry-run mode... "

    output, status = run_wayu("--dry-run backup restore path")

    if output.include?("DRY RUN") && output.include?("Would restore from backup")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected dry-run output for backup restore"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_dry_run_no_file_changes
    print "Test 6: Dry-run doesn't modify files... "

    # Get initial file states
    path_file = "#{@config_dir}/path.zsh"
    aliases_file = "#{@config_dir}/aliases.zsh"
    constants_file = "#{@config_dir}/constants.zsh"

    path_mtime = File.exist?(path_file) ? File.mtime(path_file) : nil
    aliases_mtime = File.exist?(aliases_file) ? File.mtime(aliases_file) : nil
    constants_mtime = File.exist?(constants_file) ? File.mtime(constants_file) : nil

    # Run dry-run commands
    run_wayu("--dry-run path add /tmp")
    run_wayu("-n alias add test 'echo test'")
    run_wayu("--dry-run constants add TEST_VAR value")

    # Check that files weren't modified
    path_mtime_after = File.exist?(path_file) ? File.mtime(path_file) : nil
    aliases_mtime_after = File.exist?(aliases_file) ? File.mtime(aliases_file) : nil
    constants_mtime_after = File.exist?(constants_file) ? File.mtime(constants_file) : nil

    if path_mtime == path_mtime_after &&
       aliases_mtime == aliases_mtime_after &&
       constants_mtime == constants_mtime_after
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Files were modified in dry-run mode"
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

  def print_summary
    puts
    puts "━" * 50
    total = @passed + @failed
    if @failed == 0
      puts "✓ All #{total} dry-run integration tests passed!"
    else
      puts "Results: #{@passed}/#{total} tests passed, #{@failed} failed"
    end
    puts "━" * 50
  end
end

# Run tests if executed directly
if __FILE__ == $0
  DryRunIntegrationTest.new.run
end