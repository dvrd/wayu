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
      test_migrate_refuses_unparsed_lines
      test_migrate_mixed_quotes_roundtrip
      test_migrate_rejects_to_without_from
      test_migrate_rejects_unknown_args
      test_cross_shell_honors_dry_run
      test_cross_shell_regenerates_target
      test_cross_shell_to_fish
      test_cross_shell_requires_toml
      test_schema_preserves_values_and_keys
      test_schema_refuses_unconvertible_values
      test_schema_waits_for_config_lock
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
    print "Test 8: an invalid entry refuses the whole migration up front... "
    seed_legacy_home
    # Second alias has an invalid name → validation rejects it before any write.
    File.write("#{@data_dir}/aliases.zsh", <<~ZSH)
      #!/usr/bin/env zsh
      alias ll="ls -la"
      alias bad!name="echo nope"
    ZSH
    out, status = run_wayu('migrate')
    untouched = File.exist?("#{@data_dir}/aliases.zsh") &&
                File.exist?("#{@data_dir}/constants.zsh") &&
                Dir.glob("#{@data_dir}/*.migrated").empty? &&
                !File.exist?("#{@config_dir}/wayu.toml")
    check('keep', status.exitstatus == 65 && untouched && out.include?('aliases.zsh:3') &&
                  out.include?('nothing was changed'),
          "exit=#{status.exitstatus} untouched=#{untouched}\n  #{out[-400..]}")
  end

  def test_migrate_refuses_unparsed_lines
    print "Test 8b: unparseable lines are listed and nothing is archived... "
    seed_legacy_home
    File.write("#{@data_dir}/aliases.zsh", <<~'ZSH')
      #!/usr/bin/env zsh
      alias ll='ls -lah'
      alias multi='line one
      line two'
      greet() {
        echo hi
      }
    ZSH
    File.write("#{@data_dir}/constants.zsh", <<~'ZSH')
      export EDITOR=nvim
      if [ -n "$SSH_TTY" ]; then
        export REMOTE=1
      fi
      export NOW="$(date)"
    ZSH
    out, status = run_wayu('migrate')
    untouched = File.exist?("#{@data_dir}/aliases.zsh") &&
                File.exist?("#{@data_dir}/constants.zsh") &&
                Dir.glob("#{@data_dir}/*.migrated").empty? &&
                !File.exist?("#{@config_dir}/wayu.toml")
    listed = %w[aliases.zsh:3 aliases.zsh:4 aliases.zsh:5 aliases.zsh:6
                constants.zsh:2 constants.zsh:3 constants.zsh:5].all? { |l| out.include?(l) }
    not_listed = !out.include?('aliases.zsh:2:') && !out.include?('constants.zsh:1:')
    dry_out, dry_status = run_wayu('migrate --dry-run')
    check('unparsed', status.exitstatus == 65 && untouched && listed && not_listed &&
                      dry_status.exitstatus == 65 && dry_out.include?('constants.zsh:5'),
          "exit=#{status.exitstatus} untouched=#{untouched} listed=#{listed} not_listed=#{not_listed}\n#{out}")
  end

  def test_migrate_mixed_quotes_roundtrip
    print "Test 8c: quoting styles migrate exactly (bash round-trip)... "
    FileUtils.rm_rf("#{@tmp_home}/.config")
    FileUtils.mkdir_p(@data_dir)
    File.write("#{@data_dir}/aliases.bash", <<~'BASH')
      alias ll='ls -lah'
      alias k=kubectl
      alias glf='git log --format="%h %s"'
      alias dq="echo \"quoted\" $HOME"
      alias it='echo "it'\''s"'
    BASH
    File.write("#{@data_dir}/constants.bash", <<~'BASH')
      export SINGLE='a b'
      export BARE=value
      export A=1 B=2
      export GREETING='say "hi" now'
      export ESC="tab\\there \"q\""
      export GOBIN="$HOME/go/bin"
    BASH
    probe = <<~'SH'
      shopt -s expand_aliases
      source "$1"
      alias ll k glf it
      dq
      it
      printf '%s|' "$SINGLE" "$BARE" "$A$B" "$GREETING" "$ESC" "$GOBIN"
    SH
    original, _ = Open3.capture2({ 'HOME' => @tmp_home }, 'bash', '--norc', '-c',
      "source '#{@data_dir}/aliases.bash'; #{probe}", 'probe', "#{@data_dir}/constants.bash")
    out, status = run_wayu('--shell bash migrate')
    migrated, _ = Open3.capture2({ 'HOME' => @tmp_home }, 'bash', '--norc', '-c', probe,
      'probe', "#{@data_dir}/core.bash")
    archived = File.exist?("#{@data_dir}/aliases.bash.migrated") &&
               File.exist?("#{@data_dir}/constants.bash.migrated")
    same = original.include?(%Q{quoted #{@tmp_home}\nit's\n}) &&
           original.include?(%Q{a b|value|12|say "hi" now|tab\\there "q"|#{@tmp_home}/go/bin|}) &&
           original == migrated
    check('roundtrip', status.success? && archived && same &&
                       out.include?('5 aliases, 7 constants'),
          "exit=#{status.exitstatus} archived=#{archived}\n  original=#{original.inspect}\n  migrated=#{migrated.inspect}\n#{out[-300..]}")
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

  # TOML-era install for zsh with an alias, an env value and a PATH entry.
  def seed_toml_home
    FileUtils.rm_rf("#{@tmp_home}/.config")
    FileUtils.rm_rf("#{@tmp_home}/bin1")
    FileUtils.mkdir_p("#{@tmp_home}/.config")
    FileUtils.mkdir_p("#{@tmp_home}/bin1")
    run_wayu('init --shell zsh')
    run_wayu(%q{alias add glf 'git log --format="%h %s"'})
    run_wayu(%q{const add GREETING 'say "hi" now'})
    run_wayu("path add #{@tmp_home}/bin1")
  end

  def test_cross_shell_honors_dry_run
    print "Test 11: cross-shell --dry-run writes nothing... "
    seed_toml_home
    toml_before = File.read("#{@config_dir}/wayu.toml")
    out, status = run_wayu('--dry-run migrate --from zsh --to bash')
    none = Dir.glob("#{@data_dir}/*.bash").empty?
    same = File.read("#{@config_dir}/wayu.toml") == toml_before
    check('dry', status.success? && none && same && out.include?('Would generate'),
          "exit=#{status.exitstatus} no_files=#{none} toml_same=#{same}\n#{out}")
  end

  def test_cross_shell_regenerates_target
    print "Test 12: --from zsh --to bash rebuilds bash files from wayu.toml... "
    seed_toml_home
    out, status = run_wayu('migrate --from zsh --to bash')
    init = File.read("#{@data_dir}/init.bash") rescue ''
    core = File.read("#{@data_dir}/core.bash") rescue ''
    toml = File.read("#{@config_dir}/wayu.toml")
    files_ok = init.include?('core.bash') && !init.include?('core.zsh') &&
               !core.empty? && !core.include?('(N)') && !core.include?('typeset -U')
    type_ok  = toml.match?(/^\[shell\]\s*\ntype = "bash"/)
    zsh_kept = File.exist?("#{@data_dir}/core.zsh") && File.exist?("#{@data_dir}/init.zsh")
    bash_out, bash_err, bash_status = Open3.capture3({ 'HOME' => @tmp_home }, 'bash', '--norc', '--noprofile', '-c',
      "shopt -s expand_aliases\nsource '#{@data_dir}/init.bash'\nalias glf\nprintf '%s|%s' \"$GREETING\" \"$PATH\"")
    loads = bash_status.success? && bash_err.empty? &&
            bash_out.include?(%q{glf='git log --format="%h %s"'}) &&
            bash_out.include?(%q{say "hi" now|}) && bash_out.include?("#{@tmp_home}/bin1")
    check('regen', status.success? && files_ok && type_ok && zsh_kept && loads,
          "exit=#{status.exitstatus} files=#{files_ok} type=#{type_ok} zsh_kept=#{zsh_kept} loads=#{loads}\n" \
          "  bash_out=#{bash_out.inspect} bash_err=#{bash_err.inspect}\n#{out[-400..]}")
  end

  def test_cross_shell_to_fish
    print "Test 12b: --to fish generates core.fish and switches [shell] type... "
    seed_toml_home
    _, status = run_wayu('migrate --from zsh --to fish')
    core = File.read("#{@data_dir}/core.fish") rescue ''
    init = File.read("#{@data_dir}/init.fish") rescue ''
    toml = File.read("#{@config_dir}/wayu.toml")
    ok = status.success? && core.include?('glf') && init.include?('core.fish') &&
         !init.include?('core.zsh') && toml.match?(/^type = "fish"/)
    if ok && system('command -v fish >/dev/null 2>&1')
      fish_out, _ = Open3.capture2({ 'HOME' => @tmp_home }, 'fish', '--no-config', '-c',
        "source '#{@data_dir}/init.fish'; printf '%s' \"$GREETING\"")
      ok = fish_out == %q{say "hi" now}
    end
    check('fish', ok, "exit=#{status.exitstatus}\n#{core[0..300]}")
  end

  def test_cross_shell_requires_toml
    print "Test 12c: cross-shell without wayu.toml is a config error and writes nothing... "
    seed_legacy_home
    out, status = run_wayu('migrate --from zsh --to bash')
    none = Dir.glob("#{@data_dir}/*.bash").empty? && !File.exist?("#{@config_dir}/wayu.toml")
    check('notoml', status.exitstatus == 78 && none && out.include?('wayu --shell zsh migrate'),
          "exit=#{status.exitstatus} none=#{none}\n#{out}")
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

  # Values the one-line schema parser can't read (multi-line strings, arrays)
  # used to vanish: `ll` became "" and MULTI/LIST were dropped, exit 0.
  def test_schema_refuses_unconvertible_values
    print "Test 14: migrate --schema refuses multi-line/array values, writes nothing... "
    FileUtils.rm_rf("#{@tmp_home}/.config")
    FileUtils.mkdir_p(@config_dir)
    original = <<~'TOML'
      [[aliases]]
      name = "ll"
      command = """ls -la"""

      [env] # mine
      EDITOR = "vim"
      MULTI = """
      line1"""
      LIST = ["a", "b"]
    TOML
    File.write("#{@config_dir}/wayu.toml", original)
    out, status = run_wayu('migrate --schema')
    unchanged = File.read("#{@config_dir}/wayu.toml") == original
    ok = status.exitstatus == 65 && unchanged &&
         out.include?('wayu.toml:3:') && out.include?('wayu.toml:7:') &&
         out.include?('wayu.toml:8:') && out.include?('wayu.toml:9:') &&
         !out.include?('wayu.toml:6:')
    check('schema-refuse', ok, "exit=#{status.exitstatus} unchanged=#{unchanged}\n#{out}")
  end

  # migrate --schema rewrites wayu.toml: it must hold the config lock.
  def test_schema_waits_for_config_lock
    print "Test 15: migrate --schema waits for the config lock... "
    FileUtils.rm_rf("#{@tmp_home}/.config")
    FileUtils.mkdir_p(@config_dir)
    File.write("#{@config_dir}/wayu.toml", "[[aliases]]\nname = \"gs\"\ncommand = \"git status\"\n")
    out, status, waited = run_wayu_with_config_lock_held('migrate --schema', hold: 2)
    if waited.nil?
      check('schema-lock', true) # no python3: skipped
    else
      check('schema-lock', status.success? && waited >= 1.5,
            "waited=#{waited.round(2)}s exit=#{status.exitstatus}\n#{out}")
    end
  end
end

MigrateIntegrationTest.new.run if __FILE__ == $0
