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
      test_migrate_keeps_legacy_file_on_failure
      test_migrate_rejects_to_without_from
      test_migrate_rejects_unknown_args
      test_cross_shell_honors_dry_run
      test_cross_shell_escapes_values
      test_schema_preserves_values_and_keys
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
    FileUtils.rm_rf("#{@tmp_home}/.local")
    FileUtils.mkdir_p("#{@config_dir}")
    FileUtils.mkdir_p("#{@data_dir}")
    File.write("#{@data_dir}/aliases.zsh", <<~ZSH)
      #!/usr/bin/env zsh
      alias ll="ls -la"
      alias gs="git status"
    ZSH
    File.write("#{@data_dir}/constants.zsh", <<~ZSH)
      #!/usr/bin/env zsh
      export EDITOR="nvim"
      export LANG="en_US.UTF-8"
    ZSH
    File.write("#{@data_dir}/path.zsh", <<~ZSH)
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
    legacy_kept = File.exist?("#{@data_dir}/aliases.zsh") &&
                  File.exist?("#{@data_dir}/constants.zsh") &&
                  File.exist?("#{@data_dir}/path.zsh")
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
                          toml.include?('= "/opt/homebrew/bin"') &&
                          toml.include?('= "/usr/local/bin"')
    archived = File.exist?("#{@data_dir}/aliases.zsh.migrated") &&
               File.exist?("#{@data_dir}/constants.zsh.migrated") &&
               File.exist?("#{@data_dir}/path.zsh.migrated")
    originals_gone = !File.exist?("#{@data_dir}/aliases.zsh") &&
                     !File.exist?("#{@data_dir}/constants.zsh") &&
                     !File.exist?("#{@data_dir}/path.zsh")
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

      [env]
      EXISTING_VAR = "keep me"
    TOML
    _, status = run_wayu('migrate')
    toml = File.read("#{@config_dir}/wayu.toml")
    preserved = toml.include?('existing = "already here"') &&
                toml.include?('EXISTING_VAR = "keep me"')
    appended  = toml.include?('ll = "ls -la"') && toml.include?('EDITOR = "nvim"') &&
                toml.include?('= "/opt/homebrew/bin"')
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
    FileUtils.rm_rf("#{@tmp_home}/.local")
    FileUtils.mkdir_p(@config_dir)
    FileUtils.mkdir_p("#{@tmp_home}/.local/share")
    run_wayu('init --shell zsh')
    out, status = run_wayu('migrate')
    scaffolded_untouched = File.exist?("#{@data_dir}/aliases.zsh") &&
                           !File.exist?("#{@data_dir}/aliases.zsh.migrated")
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

  def check(label, ok, detail = '')
    if ok
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  #{detail}" unless detail.empty?
      @failed += 1
    end
  end

  def test_migrate_keeps_legacy_file_on_failure
    print "Test 8: legacy file with a failing entry is NOT archived... "
    seed_legacy_home
    # Second alias has an invalid name → toml_alias_add rejects it.
    File.write("#{@data_dir}/aliases.zsh", <<~ZSH)
      #!/usr/bin/env zsh
      alias ll="ls -la"
      alias bad!name="echo nope"
    ZSH
    out, status = run_wayu('migrate')
    kept     = File.exist?("#{@data_dir}/aliases.zsh") &&
               !File.exist?("#{@data_dir}/aliases.zsh.migrated")
    others   = File.exist?("#{@data_dir}/constants.zsh.migrated")
    toml     = File.read("#{@config_dir}/wayu.toml") rescue ''
    check('keep', !status.success? && kept && others && toml.include?('ll = "ls -la"') &&
                  out.include?('failed'),
          "exit=#{status.exitstatus} kept=#{kept} others=#{others}\n  #{out[-400..]}")
  end

  def test_migrate_rejects_to_without_from
    print "Test 9: 'migrate --to bash' is a usage error and archives nothing... "
    seed_legacy_home
    out, status = run_wayu('migrate --to bash')
    untouched = File.exist?("#{@data_dir}/aliases.zsh") &&
                !File.exist?("#{@data_dir}/aliases.zsh.migrated") &&
                !File.exist?("#{@config_dir}/wayu.toml")
    check('to', status.exitstatus == 64 && untouched,
          "exit=#{status.exitstatus} untouched=#{untouched}")
  end

  def test_migrate_rejects_unknown_args
    print "Test 10: unknown migrate argument is a usage error... "
    seed_legacy_home
    _, status = run_wayu('migrate --frobnicate')
    untouched = File.exist?("#{@data_dir}/path.zsh") && !File.exist?("#{@config_dir}/wayu.toml")
    check('unknown', status.exitstatus == 64 && untouched,
          "exit=#{status.exitstatus} untouched=#{untouched}")
  end

  def test_cross_shell_honors_dry_run
    print "Test 11: cross-shell --dry-run writes nothing... "
    seed_legacy_home
    out, status = run_wayu('--dry-run migrate --from zsh --to bash')
    none = Dir.glob("#{@data_dir}/*.bash").empty?
    check('dry', status.success? && none && out.include?('Would migrate'),
          "exit=#{status.exitstatus} no_files=#{none}")
  end

  def test_cross_shell_escapes_values
    print "Test 12: cross-shell conversion quotes values safely... "
    seed_legacy_home
    File.write("#{@data_dir}/aliases.zsh", <<~'ZSH')
      #!/usr/bin/env zsh
      alias greet="echo 'hi there'"
    ZSH
    File.write("#{@data_dir}/constants.zsh", <<~'ZSH')
      #!/usr/bin/env zsh
      export MSG="it's \"fine\""
    ZSH
    _, status = run_wayu('migrate --from zsh --to fish')
    aliases = File.read("#{@data_dir}/aliases.fish") rescue ''
    consts  = File.read("#{@data_dir}/constants.fish") rescue ''
    path    = File.read("#{@data_dir}/path.fish") rescue ''
    alias_ok = aliases.include?(%q{alias greet 'echo \'hi there\''})
    const_ok = consts.include?(%q{set -gx MSG "it's \"fine\""})
    path_ok  = path.include?('set -a WAYU_PATHS "/opt/homebrew/bin"') &&
               !path.include?('WAYU_PATHS=(') && !path.include?('${WAYU_PATHS[@]}')

    # Round-trip back to bash and make sure bash agrees on the values.
    FileUtils.rm_f(Dir.glob("#{@data_dir}/*.zsh"))
    run_wayu('migrate --from fish --to bash')
    bash_out, _ = Open3.capture2('bash', '-c',
      "shopt -s expand_aliases; source '#{@data_dir}/constants.bash'; printf '%s' \"$MSG\"; " \
      "source '#{@data_dir}/aliases.bash'; alias greet")
    roundtrip_ok = bash_out.start_with?(%q{it's "fine"}) && bash_out.include?('hi there')
    check('esc', status.success? && alias_ok && const_ok && path_ok && roundtrip_ok,
          "alias=#{alias_ok} const=#{const_ok} path=#{path_ok} roundtrip=#{roundtrip_ok}\n  #{aliases}\n  #{consts}\n  #{bash_out}")
  end

  def test_schema_preserves_values_and_keys
    print "Test 13: migrate --schema decodes values once and keeps [paths] keys... "
    FileUtils.rm_rf("#{@tmp_home}/.config")
    FileUtils.mkdir_p(@config_dir)
    File.write("#{@config_dir}/wayu.toml", <<~'TOML')
      [paths]
      mybin = "/opt/my bin" # user key + comment

      [[paths]]
      path = "/usr/local/bin"

      [[aliases]]
      name = "g"
      command = "grep \"x\"" # trailing comment

      [[aliases]]
      name = "win"
      command = 'C:\Users\dan'

      [[constants]]
      name = "GREETING"
      value = "a \\ b"
    TOML
    _, status = run_wayu('migrate --schema')
    toml = File.read("#{@config_dir}/wayu.toml")
    ok = toml.include?('mybin = "/opt/my bin"') &&
         toml.include?('g = "grep \"x\""') &&
         !toml.include?('trailing comment') &&
         toml.include?('win = "C:\\\\Users\\\\dan"') &&
         toml.include?('GREETING = "a \\\\ b"') &&
         !toml.include?('[[')
    check('schema', status.success? && ok, "exit=#{status.exitstatus}\n#{toml}")
  end
end

MigrateIntegrationTest.new.run if __FILE__ == $0
