#!/usr/bin/env ruby
# Integration tests for `wayu doctor` (PATH check + --fix against wayu.toml,
# TOML validation, shell RC detection, --optimize backups).

require 'fileutils'
require 'open3'
require_relative 'test_helper'

class DoctorIntegrationTest
  include WayuTestHelper

  def initialize
    setup_test_env
  end

  def run
    puts "🔬 Testing 'wayu doctor' integration..."
    puts
    begin
      build_project
      initialize_wayu
      test_path_check_reads_wayu_toml
      test_fix_rewrites_wayu_toml_paths
      test_fix_dry_run_changes_nothing
      test_toml_check_detects_malformed
      test_commented_source_not_counted
      test_optimize_keeps_every_backup
    ensure
      FileUtils.rm_rf(@real_dir) if @real_dir
      teardown_test_env
    end
    print_summary("doctor")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def check(ok, detail = '')
    if ok
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  #{detail}" unless detail.empty?
      @failed += 1
    end
  end

  def write_paths_toml
    @real_dir = "#{@tmp_home}/realdir"
    FileUtils.mkdir_p(@real_dir)
    File.write("#{@config_dir}/wayu.toml", <<~TOML)
      [paths]
      real = "#{@real_dir}"
      gone = "/nonexistent/wayu_doctor_test"
      again = "#{@real_dir}"

      [aliases]
      ll = "ls -la"
    TOML
  end

  def test_path_check_reads_wayu_toml
    print "Test 1: PATH check reads wayu.toml [paths] (not legacy path.zsh)... "
    write_paths_toml
    out, _ = run_wayu('doctor --no-color')
    ok = out.include?('3 PATH entries') && out.include?('1 missing') && out.include?('1 duplicates')
    check(ok, out.lines.grep(/PATH/).join)
  end

  def test_fix_rewrites_wayu_toml_paths
    print "Test 2: --fix removes missing/duplicate entries from wayu.toml with one backup... "
    write_paths_toml
    before = Dir.glob("#{@data_dir}/backup/wayu.toml.backup.*").size
    out, _ = run_wayu('doctor --fix --no-color')
    toml = File.read("#{@config_dir}/wayu.toml")
    after = Dir.glob("#{@data_dir}/backup/wayu.toml.backup.*").size
    ok = toml.include?("real = \"#{@real_dir}\"") &&
         !toml.include?('nonexistent') && !toml.include?('again =') &&
         toml.include?('ll = "ls -la"') &&
         after == before + 1 &&
         out.include?('1 PATH entries, all valid')
    check(ok, "backups #{before}->#{after}\n#{toml}")
  end

  def test_fix_dry_run_changes_nothing
    print "Test 3: --dry-run --fix leaves wayu.toml untouched... "
    write_paths_toml
    before = File.read("#{@config_dir}/wayu.toml")
    out, _ = run_wayu('--dry-run doctor --fix --no-color')
    check(File.read("#{@config_dir}/wayu.toml") == before && out.include?('DRY RUN'))
  end

  def test_toml_check_detects_malformed
    print "Test 4: TOML check flags malformed wayu.toml... "
    good = File.read("#{@config_dir}/wayu.toml")
    File.write("#{@config_dir}/wayu.toml", "[paths\nx = = 1\n")
    out, _ = run_wayu('doctor --no-color')
    File.write("#{@config_dir}/wayu.toml", good)
    check(out.include?('malformed'), out.lines.grep(/TOML/).join)
  end

  def test_commented_source_not_counted
    print "Test 5: commented-out source line is not 'wayu sourced'... "
    File.write("#{@tmp_home}/.zshrc", "# source \"$HOME/.config/wayu/init.zsh\"\n")
    out, _ = run_wayu('--shell zsh doctor --no-color')
    check(out.include?('wayu not sourced'), out.lines.grep(/sourced/).join)
  end

  def test_optimize_keeps_every_backup
    print "Test 6: --optimize backs up init.zsh into backup/ each run... "
    File.write("#{@data_dir}/init.zsh", "# original init\n")
    run_wayu('--shell zsh doctor --optimize --no-color')
    run_wayu('--shell zsh doctor --optimize --no-color')
    backups = Dir.glob("#{@data_dir}/backup/init.zsh.backup.*")
    original_kept = backups.any? { |f| File.read(f) == "# original init\n" }
    syntax_ok = system('zsh', '-n', "#{@data_dir}/init.zsh")
    check(backups.size >= 2 && original_kept && syntax_ok,
          "backups=#{backups.size} original_kept=#{original_kept} zsh_syntax=#{syntax_ok}")
  end
end

DoctorIntegrationTest.new.run if __FILE__ == $0
