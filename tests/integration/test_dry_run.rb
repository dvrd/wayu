#!/usr/bin/env ruby
# Integration tests for dry-run mode

require 'open3'
require 'fileutils'
require_relative 'test_helper'

class DryRunIntegrationTest
  include WayuTestHelper

  def initialize
    setup_test_env
  end

  def run
    puts "🧪 Testing dry-run mode integration..."
    puts

    begin
      build_project
      initialize_wayu

      test_path_dry_run_add
      test_path_dry_run_remove
      test_path_dry_run_remove_missing
      test_dry_run_no_success_no_hooks
      test_init_dry_run_writes_nothing
      test_alias_dry_run_add
      test_constants_dry_run_add
      test_backup_dry_run_restore
      test_dry_run_no_file_changes
    ensure
      teardown_test_env
    end

    print_summary("dry-run")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def test_path_dry_run_add
    print "Test 1: PATH add dry-run mode... "

    output, status = run_wayu("--dry-run path add /tmp")

    if status.success? && output.include?("DRY RUN") && output.include?("Would add to wayu.toml")
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

    run_wayu("path add /tmp")
    toml = "#{@config_dir}/wayu.toml"
    before = File.read(toml)
    output, status = run_wayu("-n path rm /tmp")
    after = File.read(toml)
    run_wayu("path rm /tmp")

    if status.success? && output.include?("DRY RUN") && output.include?("Would remove from wayu.toml") &&
       !output.include?("Removed from wayu.toml") && before == after
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected dry-run preview, no success line, file unchanged"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  # Regression: dry-run remove of a missing entry printed "✅ Removed".
  def test_path_dry_run_remove_missing
    print "Test 2b: PATH remove dry-run of missing entry fails cleanly... "

    output, status = run_wayu("-n path rm /nonexistent")

    if status.exitstatus == 65 && output.include?("Not found") && !output.include?("Removed")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected exit 65 + not-found, got #{status.exitstatus}"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  # Regression: dry-run printed ✅ success, regenerated init files and ran
  # post-hooks even though nothing was written.
  def test_dry_run_no_success_no_hooks
    print "Test 2c: Dry-run prints no success and runs no hooks... "

    log = "#{@tmp_home}/hook.log"
    hooks = "#{@config_dir}/hooks.conf"
    File.write(hooks, %(pre_path_add = "echo pre >> #{log}"\npost_path_add = "echo post >> #{log}"\n) +
                      %(post_alias_add = "echo alias >> #{log}"\npost_constant_add = "echo const >> #{log}"\n))
    core = "#{@config_dir}/core.zsh"
    core_before = File.exist?(core) ? File.read(core) : nil

    out1, s1 = run_wayu("--dry-run path add /tmp")
    out2, s2 = run_wayu("--dry-run alias add dryal 'echo hi'")
    out3, s3 = run_wayu("--dry-run const add DRY_C v")
    core_after = File.exist?(core) ? File.read(core) : nil
    File.delete(hooks)

    all = out1 + out2 + out3
    if s1.success? && s2.success? && s3.success? && !File.exist?(log) &&
       !all.include?("✅") && !all.include?("successfully") && core_before == core_after
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  hook log exists: #{File.exist?(log)}; core changed: #{core_before != core_after}"
      puts "  Output: #{all}"
      @failed += 1
    end
  end

  def test_init_dry_run_writes_nothing
    print "Test 2d: init --dry-run touches nothing... "

    home = "#{@tmp_home}/fresh_home"
    FileUtils.mkdir_p(home)
    File.write("#{home}/.zshrc", "# rc\n")
    env = ENV.to_h.merge('HOME' => home)
    stdout, stderr, status = Open3.capture3(env, "#{@wayu_bin} --dry-run init --shell zsh")
    output = stdout + stderr

    if status.success? && output.include?("DRY RUN") && !Dir.exist?("#{home}/.config/wayu") &&
       File.read("#{home}/.zshrc") == "# rc\n"
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_alias_dry_run_add
    print "Test 3: Alias add dry-run mode... "

    output, status = run_wayu("--dry-run alias add gc 'git commit'")

    if status.success? && output.include?("DRY RUN") && output.include?("wayu.toml")
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

    if status.success? && output.include?("DRY RUN") && output.include?("wayu.toml")
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

end

# Run tests if executed directly
if __FILE__ == $0
  DryRunIntegrationTest.new.run
end
