#!/usr/bin/env ruby
# Integration tests for `wayu doctor` (PATH check + --fix against wayu.toml,
# TOML validation, shell startup-file detection, --json, exit status,
# --fix safety, removed --optimize).

require 'fileutils'
require 'json'
require 'open3'
require_relative 'test_helper'

class DoctorIntegrationTest
  include WayuTestHelper

  RC_FILES = %w[.zshenv .zprofile .zshrc .zlogin .bash_profile .bash_login .profile .bashrc].freeze

  def initialize
    setup_test_env
    # The developer's own ZDOTDIR must not redirect the sandboxed zsh lookups.
    ENV.delete('ZDOTDIR')
  end

  def run
    puts "🔬 Testing 'wayu doctor' integration..."
    puts
    begin
      build_project
      initialize_wayu
      test_path_check_reads_wayu_toml
      test_fix_requires_yes
      test_fix_rewrites_wayu_toml_paths
      test_fix_dry_run_changes_nothing
      test_fix_keeps_variable_paths
      test_fix_keeps_relative_paths
      test_fix_refuses_repeated_key
      test_toml_check_detects_malformed
      test_commented_source_not_counted
      test_json_output_parses
      test_global_json_flag
      test_json_rejects_fix
      test_exit_zero_when_healthy
      test_exit_nonzero_on_error
      test_bash_profile_recognized
      test_bash_prompt_command_overwrite
      test_zdotdir_recognized
      test_zshenv_recognized
      test_variable_source_recognized
      test_no_auto_install
      test_turbo_not_fixable_or_generated
      test_optimize_removed
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

  # run_wayu with extra environment overrides (nil value unsets a variable).
  def run_wayu_env(extra, args)
    env = ENV.to_h.merge('HOME' => @tmp_home).merge(extra)
    project_root = File.expand_path('../..', __dir__)
    stdout, stderr, status = Open3.capture3(env, "#{@wayu_bin} #{args}", chdir: project_root)
    [stdout.force_encoding('UTF-8'), stderr.force_encoding('UTF-8'), status]
  end

  def reset_rc_files
    RC_FILES.each { |f| FileUtils.rm_f("#{@tmp_home}/#{f}") }
    FileUtils.rm_rf("#{@tmp_home}/.zsh")
  end

  def shell_line(out)
    out.lines.each_cons(2).find { |a, _| a.include?('shell configuration') }&.join.to_s
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

  def write_clean_toml
    File.write("#{@config_dir}/wayu.toml", "[aliases]\nll = \"ls -la\"\n")
  end

  def test_path_check_reads_wayu_toml
    print "Test 1: PATH check reads wayu.toml [paths]... "
    write_paths_toml
    out, _ = run_wayu('doctor --no-color')
    ok = out.include?('3 PATH entries') && out.include?('1 missing') && out.include?('1 duplicates')
    check(ok, out.lines.grep(/PATH/).join)
  end

  def test_fix_requires_yes
    print "Test 2: --fix without --yes exits 64 and changes nothing... "
    write_paths_toml
    before = File.read("#{@config_dir}/wayu.toml")
    out, status = run_wayu('doctor --fix --no-color')
    check(status.exitstatus == 64 && File.read("#{@config_dir}/wayu.toml") == before &&
          out.include?('--yes'), "exit=#{status.exitstatus}\n#{out}")
  end

  def test_fix_rewrites_wayu_toml_paths
    print "Test 3: --fix --yes removes missing/duplicate entries with one backup... "
    write_paths_toml
    before = Dir.glob("#{@data_dir}/backup/wayu.toml.backup.*").size
    out, _ = run_wayu('doctor --fix --yes --no-color')
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
    print "Test 4: --dry-run --fix (no --yes needed) leaves wayu.toml untouched... "
    write_paths_toml
    before = File.read("#{@config_dir}/wayu.toml")
    out, _ = run_wayu('--dry-run doctor --fix --no-color')
    check(File.read("#{@config_dir}/wayu.toml") == before && out.include?('DRY RUN') &&
          out.include?('previewed') && !out.include?('applied successfully'), out)
  end

  def test_fix_keeps_variable_paths
    print "Test 5: --fix keeps entries using wayu.toml [env] or unset variables... "
    tools = "#{@tmp_home}/mytools"
    FileUtils.mkdir_p("#{tools}/bin")
    File.write("#{@config_dir}/wayu.toml", <<~TOML)
      [paths]
      mytools = "$MYTOOLS/bin"
      braced = "${MYTOOLS}"
      later = "$WAYU_DOCTOR_TEST_UNSET/bin"
      gone = "/nonexistent/wayu_doctor_test"

      [env]
      MYTOOLS = "#{tools}"
    TOML
    out, _, _ = run_wayu_env({ 'MYTOOLS' => nil, 'WAYU_DOCTOR_TEST_UNSET' => nil },
                             'doctor --fix --yes --no-color')
    toml = File.read("#{@config_dir}/wayu.toml")
    ok = toml.include?('mytools = "$MYTOOLS/bin"') && toml.include?('braced = ') &&
         toml.include?('later = ') && !toml.include?('gone =') &&
         out.include?('1 missing') && out.include?('unset variables')
    check(ok, "#{out.lines.grep(/PATH|Removed|- /).join}\n#{toml}")
  end

  # A relative entry resolves against the shell's cwd; doctor's cwd says
  # nothing about it, so --fix must not delete it as "missing".
  def test_fix_keeps_relative_paths
    print "Test 5b: --fix keeps relative entries (cwd-dependent)... "
    File.write("#{@config_dir}/wayu.toml", <<~TOML)
      [paths]
      nm = "./wayu_doctor_rel_test/.bin"
      bare = "wayu_doctor_rel_test/bin"
      gone = "/nonexistent/wayu_doctor_test"
    TOML
    out, _ = run_wayu('doctor --fix --yes --no-color')
    toml = File.read("#{@config_dir}/wayu.toml")
    ok = toml.include?('nm = ') && toml.include?('bare = ') && !toml.include?('gone =') &&
         out.include?('1 missing') && out.include?('relative paths')
    check(ok, "#{out.lines.grep(/PATH|Removed|- /).join}\n#{toml}")
  end

  # A repeated [paths] key: the duplicate's deletion removed every line of
  # the key, survivor included. --fix must refuse (78) and change nothing.
  def test_fix_refuses_repeated_key
    print "Test 5c: --fix refuses a repeated [paths] key, changes nothing... "
    dir = "#{@tmp_home}/dupkey"
    FileUtils.mkdir_p(dir)
    File.write("#{@config_dir}/wayu.toml", <<~TOML)
      [paths]
      a = "#{dir}"
      a = "#{dir}"
    TOML
    before = File.read("#{@config_dir}/wayu.toml")
    out, status = run_wayu('doctor --fix --yes --no-color')
    after = File.read("#{@config_dir}/wayu.toml")
    check(status.exitstatus == 78 && after == before && out.include?("key 'a'"),
          "exit=#{status.exitstatus}\n#{out.lines.grep(/PATH|key|Removed/).join}\n#{after}")
  end

  def test_toml_check_detects_malformed
    print "Test 6: TOML check flags malformed wayu.toml... "
    good = File.read("#{@config_dir}/wayu.toml")
    File.write("#{@config_dir}/wayu.toml", "[paths\nx = = 1\n")
    out, _ = run_wayu('doctor --no-color')
    File.write("#{@config_dir}/wayu.toml", good)
    check(out.include?('malformed'), out.lines.grep(/TOML/).join)
  end

  def test_commented_source_not_counted
    print "Test 7: commented-out source line is not 'wayu sourced'... "
    reset_rc_files
    File.write("#{@tmp_home}/.zshrc", "# source \"$HOME/.config/wayu/init.zsh\"\n")
    out, _ = run_wayu('--shell zsh doctor --no-color')
    check(out.include?('wayu not sourced'), shell_line(out))
  end

  def test_json_output_parses
    print "Test 8: doctor --json prints valid JSON only... "
    write_clean_toml
    out, _, status = run_wayu_env({}, '--shell zsh doctor --json')
    data = JSON.parse(out) rescue nil
    ok = data.is_a?(Hash) && data['checks'].is_a?(Array) && !data['checks'].empty? &&
         data['summary'].key?('errors') &&
         data['checks'].all? { |c| %w[name status message fixable].all? { |k| c.key?(k) } }
    # Exit status mirrors the error count in JSON mode too.
    ok &&= (status.exitstatus == (data['summary']['errors'] > 0 ? 78 : 0))
    check(ok, "exit=#{status.exitstatus}\n#{out[0, 300]}")
  end

  def test_global_json_flag
    print "Test 9: --json before the command also yields JSON... "
    out, _, _ = run_wayu_env({}, '--json --shell zsh doctor')
    data = JSON.parse(out) rescue nil
    check(data.is_a?(Hash) && data.key?('summary'), out[0, 300])
  end

  def test_json_rejects_fix
    print "Test 10: --json --fix is a usage error... "
    _, status = run_wayu('doctor --json --fix --yes')
    check(status.exitstatus == 64, "exit=#{status.exitstatus}")
  end

  def test_exit_zero_when_healthy
    print "Test 11: exit 0 when no check reports an error... "
    reset_rc_files
    write_clean_toml
    File.write("#{@tmp_home}/.zshrc", "source \"$HOME/.config/wayu/init.zsh\"\n")
    out, status = run_wayu('--shell zsh doctor --no-color')
    check(status.exitstatus == 0 && out.include?('0 errors'), "exit=#{status.exitstatus}\n#{out}")
  end

  def test_exit_nonzero_on_error
    print "Test 12: exit 78 when a check reports an error... "
    File.write("#{@config_dir}/wayu.toml", "[paths\nx = = 1\n")
    _, status = run_wayu('--shell zsh doctor --no-color')
    _, _, jstatus = run_wayu_env({}, '--shell zsh doctor --json')
    write_clean_toml
    check(status.exitstatus == 78 && jstatus.exitstatus == 78,
          "human=#{status.exitstatus} json=#{jstatus.exitstatus}")
  end

  def test_bash_profile_recognized
    print "Test 13: bash source line in ~/.bash_profile (where init writes) counts... "
    reset_rc_files
    File.write("#{@tmp_home}/.bashrc", "# interactive bits\n")
    File.write("#{@tmp_home}/.bash_profile", "source \"$HOME/.config/wayu/init.bash\"\n")
    out, _ = run_wayu('--shell bash doctor --no-color')
    ok = shell_line(out).include?('wayu sourced in ~/.bash_profile') && !out.include?('.zshrc')
    check(ok, shell_line(out))
  end

  # OKAMI-176: a later rc line replacing PROMPT_COMMAND drops wayu's
  # _wayu_paths_sync hook; appending keeps it and is not reported.
  def test_bash_prompt_command_overwrite
    print "Test 13b: bash rc replacing PROMPT_COMMAND after wayu is a warning... "
    reset_rc_files
    File.write("#{@tmp_home}/.bashrc", "source \"$HOME/.config/wayu/init.bash\"\n" \
                                       "PROMPT_COMMAND='history -a'\n" \
                                       "PROMPT_COMMAND=\"${PROMPT_COMMAND:+$PROMPT_COMMAND;}x\"\n")
    out, status = run_wayu('--shell bash doctor --no-color')
    warn = out.lines.each_cons(2).find { |a, _| a.include?('PROMPT_COMMAND') }&.join.to_s
    File.write("#{@tmp_home}/.bashrc", "source \"$HOME/.config/wayu/init.bash\"\nPROMPT_COMMAND+=';x'\n")
    clean, = run_wayu('--shell bash doctor --no-color')
    zsh, = run_wayu('--shell zsh doctor --no-color')
    ok = warn.include?('~/.bashrc:2') && !warn.include?('~/.bashrc:3') &&
         !clean.include?('PROMPT_COMMAND') && !zsh.include?('PROMPT_COMMAND')
    check(ok, "warn=#{warn.inspect} status=#{status.exitstatus}")
  end

  def test_zdotdir_recognized
    print "Test 14: $ZDOTDIR/.zshrc is scanned when ZDOTDIR is set... "
    reset_rc_files
    FileUtils.mkdir_p("#{@tmp_home}/.zsh")
    File.write("#{@tmp_home}/.zsh/.zshrc", "source \"$HOME/.config/wayu/init.zsh\"\n")
    out, _, _ = run_wayu_env({ 'ZDOTDIR' => "#{@tmp_home}/.zsh" }, '--shell zsh doctor --no-color')
    check(shell_line(out).include?('wayu sourced in ~/.zsh/.zshrc'), shell_line(out))
  end

  def test_zshenv_recognized
    print "Test 15: source line in ~/.zshenv counts even with a ~/.zshrc... "
    reset_rc_files
    File.write("#{@tmp_home}/.zshrc", "# prompt stuff\n")
    File.write("#{@tmp_home}/.zshenv", "source ~/.config/wayu/init.zsh\n")
    out, _ = run_wayu('--shell zsh doctor --no-color')
    check(shell_line(out).include?('wayu sourced in ~/.zshenv'), shell_line(out))
  end

  def test_variable_source_recognized
    print "Test 16: `source $WAYU/init.zsh` and eval setups count... "
    reset_rc_files
    File.write("#{@tmp_home}/.zshrc", "source \"$WAYU/init.zsh\"\n")
    out1, _ = run_wayu('--shell zsh doctor --no-color')
    File.write("#{@tmp_home}/.zshrc", "eval \"$(wayu build eval)\"\n")
    out2, _ = run_wayu('--shell zsh doctor --no-color')
    check(shell_line(out1).include?('wayu sourced') && shell_line(out2).include?('wayu sourced'),
          shell_line(out1) + shell_line(out2))
  end

  def test_no_auto_install
    print "Test 17: wayu off PATH (./bin/wayu in CWD) is report-only, never installed... "
    write_paths_toml
    env = { 'PATH' => '/usr/bin:/bin' }
    jout, _, _ = run_wayu_env(env, '--shell zsh doctor --json')
    inst = (JSON.parse(jout)['checks'].find { |c| c['name'] == 'wayu installation' } rescue nil)
    out, _, _ = run_wayu_env(env, '--shell zsh doctor --fix --yes --no-color')
    ok = inst && inst['fixable'] == false && inst['status'] == 'warning' &&
         !out.include?('Installing') && !out.include?('/usr/local/bin')
    check(ok, "#{inst.inspect}\n#{out.lines.grep(/install/i).join}")
  end

  def test_turbo_not_fixable_or_generated
    print "Test 18: missing turbo.zsh is not fixable and --fix never generates it... "
    reset_rc_files
    File.write("#{@tmp_home}/.zshrc", "source \"$HOME/.config/wayu/init.zsh\"\n")
    FileUtils.rm_f("#{@data_dir}/turbo.zsh")
    jout, _, _ = run_wayu_env({}, '--shell zsh doctor --json')
    turbo = (JSON.parse(jout)['checks'].find { |c| c['name'] == 'turbo export' } rescue nil)
    run_wayu('--shell zsh doctor --fix --yes --no-color')
    ok = turbo && turbo['status'] == 'ok' && turbo['fixable'] == false &&
         !File.exist?("#{@data_dir}/turbo.zsh")
    check(ok, turbo.inspect)
  end

  def test_optimize_removed
    print "Test 19: --optimize is rejected (exit 64) and leaves init.zsh alone... "
    File.write("#{@data_dir}/init.zsh", "# original init\n")
    out, status = run_wayu('--shell zsh doctor --optimize --no-color')
    check(status.exitstatus == 64 && File.read("#{@data_dir}/init.zsh") == "# original init\n" &&
          out.include?('removed'), "exit=#{status.exitstatus}\n#{out}")
  end
end

DoctorIntegrationTest.new.run if __FILE__ == $0
