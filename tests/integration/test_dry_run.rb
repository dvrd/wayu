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
      test_unknown_flag_rejected
      test_trailing_dry_run_on_value_add
      test_literal_values_after_double_dash
      test_pre_hooks_skip_failed_ops
      test_hook_nested_shell_no_injection
      test_hook_double_quoted_placeholder_refused
      test_hook_double_quoted_post_hook_blocks_write
      test_hooks_list_flags_invalid
    ensure
      teardown_test_env
    end

    print_summary("dry-run")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def check(label, ok, detail)
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

  # OKAMI-231: a typo in a safety flag must fail, never perform the write.
  def test_unknown_flag_rejected
    toml = "#{@config_dir}/wayu.toml"
    before = File.read(toml)
    results = [
      run_wayu("path add /tmp --dryrun"),
      run_wayu("path list --bogus"),
      run_wayu("init --template nonexistent"),
      run_wayu("alias rm x --yess"),
    ]
    after = File.read(toml)
    ok = results.all? { |out, st| st.exitstatus == 64 && out.include?("Unknown option") } && before == after
    check("Test 7: unknown flags exit 64 and write nothing", ok,
          "Got: #{results.map { |o, s| [s.exitstatus, o[0, 120]] }.inspect}")

    # Documented command-local flags keep working.
    ok2 = [
      run_wayu("doctor --json"),
      run_wayu("path list --full"),
      run_wayu("backup list --json"),
      run_wayu("plugin search --category git"),
      run_wayu("path list -h"),
    ].all? { |_out, st| st.exitstatus != 64 }
    check("Test 7b: documented flags still accepted", ok2, "a documented flag was rejected")
  end

  # OKAMI-231: `alias add x y --dry-run` previews instead of writing "y --dry-run".
  def test_trailing_dry_run_on_value_add
    toml = "#{@config_dir}/wayu.toml"
    before = File.read(toml)
    out1, st1 = run_wayu("alias add trailx echo hi --dry-run")
    out2, st2 = run_wayu("const add TRAILC v --dry-run")
    after = File.read(toml)
    ok = st1.success? && st2.success? && out1.include?("DRY RUN") && out2.include?("DRY RUN") && before == after
    check("Test 8: trailing --dry-run on alias/const add writes nothing", ok,
          "out1=#{out1[0, 200]} out2=#{out2[0, 200]} changed=#{before != after}")
  end

  # `--` and the add value keep dash tokens literal (4.4.3 behavior).
  def test_literal_values_after_double_dash
    run_wayu("alias add litd -- helm install --dry-run")
    run_wayu("alias add litg grep -n")
    _out, st = run_wayu("const add LITNEG -5")
    toml = File.read("#{@config_dir}/wayu.toml")
    ok = st.success? && toml.include?('litd = "helm install --dry-run"') &&
         toml.include?('litg = "grep -n"') && toml.include?('LITNEG = "-5"')
    check("Test 9: literal dash values after -- / in value position", ok, "toml=#{toml}")
    run_wayu("alias rm litd")
    run_wayu("alias rm litg")
    run_wayu("const rm LITNEG")
  end

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
  # OKAMI-230: pre-hooks fire only for operations that will really write.
  def test_pre_hooks_skip_failed_ops
    log = "#{@tmp_home}/prehook.log"
    hooks = "#{@config_dir}/hooks.conf"
    File.write(hooks, %(pre_alias_add = echo add {name} >> #{log}\n) +
                      %(pre_alias_remove = echo rm {name} >> #{log}\n) +
                      %(pre_constant_add = echo cadd {name} >> #{log}\n) +
                      %(pre_path_add = echo padd {path} >> #{log}\n) +
                      %(pre_path_remove = echo prm {path} >> #{log}\n))
    run_wayu("path add /tmp")
    File.delete(log) if File.exist?(log)
    run_wayu("alias add bad-name! x")   # invalid name
    run_wayu("alias add if x")          # reserved word
    run_wayu("alias rm NOPE_MISSING")   # not found
    run_wayu("const add 1BAD v")        # invalid name
    run_wayu("path add /tmp")           # duplicate (NOOP)
    run_wayu("path rm /nonexistent/nope") # not found
    phantom = File.exist?(log) ? File.read(log) : ""
    run_wayu("alias add realal x")      # real change: hook fires
    real = File.exist?(log) ? File.read(log) : ""
    run_wayu("alias rm realal")
    run_wayu("path rm /tmp")
    File.delete(hooks)
    check("Test 10: pre-hooks skip invalid / missing / no-op operations",
          phantom.empty? && real.include?("add realal"),
          "phantom=#{phantom.inspect} real=#{real.inspect}")
  end

  # OKAMI-230: a placeholder inside a nested `sh -c '...'` must not execute
  # the value.
  def test_hook_nested_shell_no_injection
    log = "#{@tmp_home}/nested.log"
    hooks = "#{@config_dir}/hooks.conf"
    File.write(hooks, %(post_alias_add = sh -c 'echo "a {name}={value}" >> #{log}'\n) +
                      %(post_alias_remove = bash -c 'echo r {name} >> #{log}'\n))
    pwn = "#{@tmp_home}/PWNED"
    pwn2 = "#{@tmp_home}/PWNED2"
    _o, st = run_wayu(%(alias add nest 'echo $(touch #{pwn}) `touch #{pwn2}`; touch #{pwn}'))
    run_wayu("alias rm nest")
    content = File.exist?(log) ? File.read(log) : ""
    File.delete(hooks)
    check("Test 11: nested-shell hook placeholders never execute values",
          st.success? && !File.exist?(pwn) && !File.exist?(pwn2) &&
            content.include?("$(touch #{pwn})") && content.include?("r nest"),
          "pwned=#{File.exist?(pwn)}/#{File.exist?(pwn2)} log=#{content.inspect}")
  end

  # Maintainer decision: a placeholder inside "..." is refused. The outer
  # shell expands it, then a nested sh -c "..." re-parses the value as code.
  def test_hook_double_quoted_placeholder_refused
    hooks = "#{@config_dir}/hooks.conf"
    pwn = "#{@tmp_home}/PWNED"
    toml = "#{@config_dir}/wayu.toml"
    File.write(hooks, %(# c\npre_alias_add = sh -c "echo {value}"\n))
    before = File.read(toml)
    out, st = run_wayu(%(alias add zz 'echo hi; touch #{pwn}'))
    after = File.read(toml)

    # Same hook with '...' and unquoted still runs and substitutes safely.
    log = "#{@tmp_home}/ok.log"
    File.write(hooks, %(pre_alias_add = sh -c 'echo q {value} >> #{log}'\n) +
                      %(post_alias_add = echo u {name} >> #{log}\n))
    _o2, st2 = run_wayu(%(alias add zz2 'echo hi; touch #{pwn}'))
    logged = File.exist?(log) ? File.read(log) : ""
    run_wayu("alias rm zz2")
    File.delete(hooks)
    check("Test 12: placeholder inside \"...\" refused (exit 78, nothing written)",
          st.exitstatus == 78 && !File.exist?(pwn) && before == after &&
            out.include?("line 2: pre_alias_add") && out.include?("WAYU_HOOK_") &&
            st2.success? && logged.include?("q echo hi; touch #{pwn}") &&
            logged.include?("u zz2") && !File.exist?(pwn),
          "st=#{st.exitstatus} pwned=#{File.exist?(pwn)} changed=#{before != after} " \
          "st2=#{st2.exitstatus} log=#{logged.inspect}\n  out=#{out}")
  end

  # An invalid post-hook must stop the operation before the write, not after.
  def test_hook_double_quoted_post_hook_blocks_write
    hooks = "#{@config_dir}/hooks.conf"
    toml = "#{@config_dir}/wayu.toml"
    File.write(hooks, %(post_path_add = echo "added {path}"\n))
    before = File.read(toml)
    out1, st1 = run_wayu("path add /usr")
    out2, st2 = run_wayu("const add DQ_HOOK v")
    out3, st3 = run_wayu("--dry-run alias add dqal x")
    after = File.read(toml)
    File.delete(hooks)
    check("Test 13: invalid post-hook blocks path/const add before writing",
          [st1, st2, st3].all? { |s| s.exitstatus == 78 } && before == after,
          "st=#{[st1, st2, st3].map(&:exitstatus)} changed=#{before != after}\n  out=#{out1}#{out2}#{out3}")
  end

  def test_hooks_list_flags_invalid
    hooks = "#{@config_dir}/hooks.conf"
    File.write(hooks, %(pre_path_add = echo ok {path}\npost_alias_add = eval "x={name}"\n))
    out, st = run_wayu("hooks")
    File.delete(hooks)
    check("Test 14: `wayu hooks` flags a double-quoted placeholder as invalid",
          st.success? && out.include?("INVALID (line 2)") && out.scan("INVALID").size == 1,
          "out=#{out}")
  end

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
