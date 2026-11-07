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
    ok = eval_clean && zsh_out.include?("hello") && zsh_out.include?("exll") &&
         miss.exitstatus == 78 && gen.success? && File.exist?(turbo) && cur.exitstatus == 0
    report("Test 5: export --eval is clean + evalable, --check reports staleness", ok,
           "eval_clean=#{eval_clean} zsh=#{zsh_out.inspect} miss=#{miss.exitstatus} gen=#{gen.exitstatus} cur=#{cur.exitstatus}")
    run_wayu("const rm EXPORT_T")
    run_wayu("alias rm exll")
  end

  def test_export_refuses_fish_and_build_rejects_unknown
    _o1, fish_turbo = run_wayu("--shell fish export")
    _o2, fish_eval = run_wayu("--shell fish export --eval")
    _o3, bogus_export = run_wayu("export bogus")
    _o4, bogus_build = run_wayu("build bogus")
    _o5, build_eval = run_wayu("build eval")
    ok = [fish_turbo, fish_eval, bogus_export, bogus_build].all? { |s| s.exitstatus == 64 } && build_eval.success?
    report("Test 6: fish export refused, unknown export/build targets exit 64", ok,
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
    has_aliases = out.match?(/Aliases \(from wayu\.toml/)
    if status.success? && has_heading && has_sum && has_path && has_aliases
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  heading=#{has_heading} sum=#{has_sum} path=#{has_path} aliases=#{has_aliases}"
      @failed += 1
    end
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
