#!/usr/bin/env ruby
# Integration tests for `wayu migrate` (legacy shell files -> wayu.toml).
#
# Before the v3.10 source-of-truth refactor, users kept PATH / aliases /
# constants in separate shell files. The migrate command reads those legacy
# files, writes the equivalent wayu.toml, and archives the originals so a
# re-run is a clean no-op.

require 'fileutils'
require 'open3'
require_relative 'test_helper'

class MigrateIntegrationTest
  include WayuTestHelper

  def initialize
    setup_test_env
  end

  def run
    puts "🔄 Testing 'wayu migrate' integration..."
    puts
    begin
      build_project
      test_migrate_dry_run_preview
      test_migrate_all_three_legacy_files
      test_migrate_preserves_existing_toml
      test_migrate_rerun_is_noop
      test_migrate_reports_zero_when_nothing_to_do
      test_migrate_skips_scaffolded_only_files
      test_toml_convert_delegates_to_migrate
    ensure
      teardown_test_env
    end
    print_summary("migrate")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  # Fresh HOME with preseeded legacy zsh config files. No wayu.toml so this
  # simulates a pre-v3.10 install.
  def seed_legacy_home
    FileUtils.rm_rf("#{@tmp_home}/.config")
    FileUtils.mkdir_p("#{@config_dir}")
    File.write("#{@config_dir}/aliases.zsh", <<~ZSH)
      #!/usr/bin/env zsh
      alias ll="ls -la"
      alias gs="git status"
    ZSH
    File.write("#{@config_dir}/constants.zsh", <<~ZSH)
      #!/usr/bin/env zsh
      export EDITOR="nvim"
      export LANG="en_US.UTF-8"
    ZSH
    File.write("#{@config_dir}/path.zsh", <<~ZSH)
      #!/usr/bin/env zsh
      WAYU_PATHS=(
        "/opt/homebrew/bin"
        "/usr/local/bin"
      )
    ZSH
  end

  def test_migrate_dry_run_preview
    print "Test 1: --dry-run reports files but doesn't write toml... "
    seed_legacy_home
    out, status = run_wayu('migrate --dry-run')
    toml_absent = !File.exist?("#{@config_dir}/wayu.toml")
    preview_ok  = out.include?('Dry-run mode') && out.include?('aliases.zsh') &&
                  out.include?('ll = ...')
    legacy_kept = File.exist?("#{@config_dir}/aliases.zsh") &&
                  File.exist?("#{@config_dir}/constants.zsh") &&
                  File.exist?("#{@config_dir}/path.zsh")
    if status.success? && toml_absent && preview_ok && legacy_kept
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  exit_ok=#{status.success?} toml_absent=#{toml_absent} preview_ok=#{preview_ok} legacy_kept=#{legacy_kept}"
      @failed += 1
    end
  end

  def test_migrate_all_three_legacy_files
    print "Test 2: real migrate writes toml + archives legacy files... "
    seed_legacy_home
    out, status = run_wayu('migrate')
    toml = File.exist?("#{@config_dir}/wayu.toml") ? File.read("#{@config_dir}/wayu.toml") : ''

    toml_has_everything = toml.include?('ll = "ls -la"') &&
                          toml.include?('gs = "git status"') &&
                          toml.include?('EDITOR = "nvim"') &&
                          toml.include?('LANG = "en_US.UTF-8"') &&
                          toml.include?('path = "/opt/homebrew/bin"') &&
                          toml.include?('path = "/usr/local/bin"')
    archived = File.exist?("#{@config_dir}/aliases.zsh.migrated") &&
               File.exist?("#{@config_dir}/constants.zsh.migrated") &&
               File.exist?("#{@config_dir}/path.zsh.migrated")
    originals_gone = !File.exist?("#{@config_dir}/aliases.zsh") &&
                     !File.exist?("#{@config_dir}/constants.zsh") &&
                     !File.exist?("#{@config_dir}/path.zsh")
    summary_ok = out.include?('Migration complete: 2 paths, 2 aliases, 2 constants')

    if status.success? && toml_has_everything && archived && originals_gone && summary_ok
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  exit_ok=#{status.success?} toml_ok=#{toml_has_everything} archived=#{archived} originals_gone=#{originals_gone} summary_ok=#{summary_ok}"
      @failed += 1
    end
  end

  def test_migrate_preserves_existing_toml
    print "Test 3: migrate appends to an existing wayu.toml... "
    seed_legacy_home
    File.write("#{@config_dir}/wayu.toml", <<~TOML)
      [shell]
      type = "Zsh"

      [aliases]
      existing = "already here"

      [constants]
      EXISTING_VAR = "keep me"
    TOML
    _, status = run_wayu('migrate')
    toml = File.read("#{@config_dir}/wayu.toml")
    preserved = toml.include?('existing = "already here"') &&
                toml.include?('EXISTING_VAR = "keep me"')
    appended  = toml.include?('ll = "ls -la"') && toml.include?('EDITOR = "nvim"') &&
                toml.include?('path = "/opt/homebrew/bin"')
    if status.success? && preserved && appended
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  exit_ok=#{status.success?} preserved=#{preserved} appended=#{appended}"
      @failed += 1
    end
  end

  def test_migrate_rerun_is_noop
    print "Test 4: rerun reports 'No legacy shell config files found'... "
    seed_legacy_home
    run_wayu('migrate')   # first pass archives everything
    out, status = run_wayu('migrate')
    # Preserve timestamp of wayu.toml so we can assert nothing was rewritten.
    toml_mtime_before = File.mtime("#{@config_dir}/wayu.toml")
    sleep 0.05
    out2, _ = run_wayu('migrate')
    toml_mtime_after = File.mtime("#{@config_dir}/wayu.toml")

    noop_msg = out.include?('No legacy shell config files found')
    idempotent = out2.include?('No legacy shell config files found') &&
                 toml_mtime_before == toml_mtime_after
    if status.success? && noop_msg && idempotent
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  exit_ok=#{status.success?} first_run_noop=#{noop_msg} idempotent=#{idempotent}"
      @failed += 1
    end
  end

  def test_migrate_reports_zero_when_nothing_to_do
    print "Test 5: fresh HOME (no legacy files) reports nothing to do... "
    FileUtils.rm_rf("#{@tmp_home}/.config")
    FileUtils.mkdir_p(@config_dir)
    out, status = run_wayu('migrate')
    ok = status.success? && out.include?('No legacy shell config files found')
    if ok
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  exit_ok=#{status.success?} msg_ok=#{out.include?('No legacy shell config files')}"
      @failed += 1
    end
  end

  def test_migrate_skips_scaffolded_only_files
    print "Test 6: skips files that only contain wayu scaffolding... "
    # `wayu init` writes scaffolded headers + helper loops into aliases.zsh
    # / constants.zsh / path.zsh but with no user content. Those should be
    # treated as empty, not as "has legacy content to migrate".
    FileUtils.rm_rf("#{@tmp_home}/.config")
    FileUtils.mkdir_p(@config_dir)
    run_wayu('init --shell zsh')
    out, status = run_wayu('migrate')
    scaffolded_untouched = File.exist?("#{@config_dir}/aliases.zsh") &&
                           !File.exist?("#{@config_dir}/aliases.zsh.migrated")
    if status.success? && out.include?('No legacy shell config files') && scaffolded_untouched
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  exit_ok=#{status.success?} scaffolded_untouched=#{scaffolded_untouched}"
      puts "  output: #{out[0..400]}"
      @failed += 1
    end
  end

  def test_toml_convert_delegates_to_migrate
    print "Test 7: 'wayu toml convert' delegates to migrate... "
    seed_legacy_home
    out, status = run_wayu('toml convert')
    toml_ok = File.exist?("#{@config_dir}/wayu.toml") &&
              File.read("#{@config_dir}/wayu.toml").include?('ll = "ls -la"')
    delegated = out.include?('`wayu toml convert` now runs `wayu migrate`') ||
                out.include?('Migration complete')
    if status.success? && toml_ok && delegated
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  exit_ok=#{status.success?} toml_ok=#{toml_ok} delegated=#{delegated}"
      @failed += 1
    end
  end
end

MigrateIntegrationTest.new.run if __FILE__ == $0
