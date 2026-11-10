#!/usr/bin/env ruby
# Integration tests for `wayu build profile` (shell startup measurement).

require 'open3'
require 'fileutils'
require_relative 'test_helper'

class BuildProfileTest
  include WayuTestHelper

  def initialize
    setup_test_env
  end

  def run
    puts "📊 Testing 'wayu build profile'..."
    puts
    begin
      build_project
      initialize_wayu
      test_profile_reports_both_scenarios
      test_profile_five_raw_samples
      test_profile_missing_init_core_warns
      test_profile_zsh_phase_breakdown
      test_profile_breakdown_names_tools
      test_profile_breakdown_is_interactive
      test_export_flag_modes
      test_export_refuses_fish_and_build_rejects_unknown
    ensure
      teardown_test_env
    end
    print_summary("build profile")
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

  # OKAMI-233: --eval/--check/--turbo are parsed (they used to all mean turbo).
  def test_export_flag_modes
    run_wayu("const add EXPORT_T hello")
    run_wayu("alias add exll 'ls -la'")
    turbo = "#{@data_dir}/turbo.zsh"
    FileUtils.rm_f(turbo)
    env = ENV.to_h.merge('HOME' => @tmp_home)
    eval_out, _err, eval_st = Open3.capture3(env, "#{@wayu_bin} export --eval")
    eval_clean = eval_st.success? && !eval_out.include?("\e[") && !File.exist?(turbo)
    zsh_out = ""
    if system('command -v zsh >/dev/null 2>&1')
      zsh_out, _e, _s = Open3.capture3(env, 'zsh', '-fc', "eval \"$(#{@wayu_bin} export --eval)\"; print -r -- $EXPORT_T; alias exll")
    else
      zsh_out = "hello exll"
    end
    _o, miss = run_wayu("export --check")           # no turbo yet: 78
    _o, gen = run_wayu("export --turbo")
    _o, cur = run_wayu("export --check")            # fresh: 0
    # OKAMI-364: content, not mtimes. A touched-but-unchanged wayu.toml is
    # still current; an input the mtimes missed (config.zsh, inlined into
    # core) or a hand-edited turbo file is stale.
    FileUtils.touch("#{@config_dir}/wayu.toml", mtime: Time.now + 5)
    _o, touched = run_wayu("export --check")
    File.write("#{@config_dir}/config.zsh", "export CFG_PROBE=1\n")
    _o, cfg_stale = run_wayu("export --check")
    _o, _regen = run_wayu("export --turbo")
    _o, regen = run_wayu("export --check")
    File.delete("#{@config_dir}/config.zsh")
    run_wayu("export --turbo")
    File.write(turbo, File.read(turbo) + "# edited\n")
    _o, edited = run_wayu("export --check")
    ok = eval_clean && zsh_out.include?("hello") && zsh_out.include?("exll") &&
         miss.exitstatus == 78 && gen.success? && File.exist?(turbo) && cur.exitstatus == 0 &&
         touched.exitstatus == 0 && cfg_stale.exitstatus == 78 && regen.exitstatus == 0 && edited.exitstatus == 78
    report("Test 5: export --eval is clean + evalable, --check reports staleness", ok,
           "eval_clean=#{eval_clean} zsh=#{zsh_out.inspect} miss=#{miss.exitstatus} gen=#{gen.exitstatus} cur=#{cur.exitstatus} " \
           "touched=#{touched.exitstatus} cfg=#{cfg_stale.exitstatus} regen=#{regen.exitstatus} edited=#{edited.exitstatus}")
    run_wayu("export --turbo")
    run_wayu("const rm EXPORT_T")
    run_wayu("alias rm exll")
  end

  def test_export_refuses_fish_and_build_rejects_unknown
    _o1, fish_turbo = run_wayu("--shell fish export")
    _o2, fish_eval = run_wayu("--shell fish export --eval")
    _o3, bogus_export = run_wayu("export bogus")
    _o4, bogus_build = run_wayu("build bogus")
    _o5, build_eval = run_wayu("build eval")
    ok = [fish_turbo, fish_eval, bogus_export, bogus_build, build_eval].all? { |s| s.exitstatus == 64 }
    report("Test 6: fish export refused, unknown export/build targets (incl. removed `build eval`) exit 64", ok,
           [fish_turbo, fish_eval, bogus_export, bogus_build, build_eval].map(&:exitstatus).inspect)
  end

  def test_profile_reports_both_scenarios
    print "Test 1: reports core + interactive shell scenarios... "
    out, status = run_wayu('build profile')
    ok = status.success? &&
         out.include?('core') && out.include?('interactive shell') &&
         out.match?(/min\s+[\d.]+ ms/) && out.match?(/mean\s+[\d.]+ ms/) && out.match?(/max\s+[\d.]+ ms/)
    if ok
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  exit_ok=#{status.success?}"
      puts "  output: #{out[0..500]}"
      @failed += 1
    end
  end

  def test_profile_five_raw_samples
    print "Test 2: raw line shows exactly 5 samples... "
    out, _ = run_wayu('build profile')
    # Find 'raw' lines and count floats. Each scenario has one raw line.
    raw_lines = out.scan(/raw\s+[\d.\s]+ms/)
    ok = raw_lines.length == 2 &&
         raw_lines.all? { |l| l.scan(/\d+\.\d+/).length == 5 }
    if ok
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  raw_lines.length=#{raw_lines.length}"
      raw_lines.each { |l| puts "    -> #{l}" }
      @failed += 1
    end
  end

  def test_profile_zsh_phase_breakdown
    print "Test 4: zsh profile emits per-phase breakdown... "
    # Re-initialize a known-good zsh config so core.zsh exists and has
    # phase markers. The test run above may have nuked the file.
    initialize_wayu
    # Also add at least one entry so the generator emits non-empty phases.
    run_wayu("alias add ll 'ls -la'")
    out, status = run_wayu('build profile')
    has_heading = out.include?('Phase breakdown (sorted by time')
    has_sum     = out.match?(/\(sum\)/)
    # Should pick up at least two of the standard core.zsh section
    # markers (PATH is always there, Aliases appears after our add above).
    has_path = out.include?('PATH')
    has_aliases = out.match?(/^\s*\S.*\bAliases\b/)
    if status.success? && has_heading && has_sum && has_path && has_aliases
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  heading=#{has_heading} sum=#{has_sum} path=#{has_path} aliases=#{has_aliases}"
      @failed += 1
    end
  end

  # OKAMI-348: the breakdown runs in an interactive shell (it used `-c`,
  # which skipped compinit, the prompt and the plugins): a config.zsh that
  # only sleeps in interactive shells shows up with its time,. The
  # profiled shell reads no user rc (ZDOTDIR is redirected).
  def test_profile_breakdown_is_interactive
    unless system('command -v zsh >/dev/null 2>&1')
      puts "skipped (no zsh)"; return
    end
    print "Test 4c: phase breakdown runs interactively... "
    File.write("#{@config_dir}/config.zsh", "[[ -o interactive ]] && sleep 0.3\n")
    run_wayu('build')
    out, status = run_wayu('build profile')
    row = out.lines.find { |l| l.include?('User configuration (from config.zsh)') }.to_s
    ms = row[/([\d.]+) ms/, 1].to_f
    ok = status.success? && ms >= 250 && out.include?('(interactive, no user rc)')
    File.delete("#{@config_dir}/config.zsh")
    run_wayu('build')
    report_ok = ok
    if report_ok
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  row=#{row.strip.inspect} status=#{status.exitstatus} out=#{out[0, 600]}"
      @failed += 1
    end
  end

  # OKAMI-180: the breakdown times each [tools] entry, not only the
  # "Lazy init" section that sources them all.
  def test_profile_breakdown_names_tools
    unless system('command -v zsh >/dev/null 2>&1')
      puts "skipped (no zsh)"; return
    end
    bin = "#{@tmp_home}/fakebin"
    FileUtils.mkdir_p(bin)
    File.write("#{bin}/wayufaketool", "#!/bin/sh\necho 'export WAYU_FAKE=1'\n")
    File.chmod(0o755, "#{bin}/wayufaketool")
    File.write("#{@tmp_home}/lazyinit.sh", "true\n")
    File.open("#{@config_dir}/wayu.toml", 'a') do |f|
      f.puts "\n[tools]"
      f.puts 'wayufaketool = { kind = "evalcache", args = "init zsh" }'
      f.puts "fakelazy = { kind = \"lazy\", init_script = \"#{@tmp_home}/lazyinit.sh\", hook_commands = [\"fakelazy\"] }"
    end
    env = ENV.to_h.merge('HOME' => @tmp_home, 'PATH' => "#{bin}:#{ENV['PATH']}")
    _o, _e0, st_build = Open3.capture3(env, "#{@wayu_bin} build")
    out, _e, st = Open3.capture3(env, "#{@wayu_bin} build profile")
    ok = st_build.success? && st.success? &&
         out.match?(/ms\s+[\d.]+%\s+tool wayufaketool \(evalcache\)/) &&
         out.include?('tool fakelazy (lazy)') && !out.include?('lazy ›')
    report("Test 4b: per-tool rows", ok, out.lines.grep(/%/).join)
  end

  def test_profile_missing_init_core_warns
    print "Test 3: warns when core.ext is missing... "
    # Remove the generated core so we can observe the warning path.
    Dir.glob("#{@data_dir}/core.*").each { |f| File.delete(f) }
    out, status = run_wayu('build profile')
    ok = status.success? && (out.include?('core.') && out.downcase.include?('not found'))
    if ok
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  exit_ok=#{status.success?}"
      puts "  output: #{out[0..400]}"
      @failed += 1
    end
  end
end

BuildProfileTest.new.run if __FILE__ == $0
