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
    ensure
      teardown_test_env
    end
    print_summary("build profile")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def test_profile_reports_both_scenarios
    print "Test 1: reports init-core + interactive shell scenarios... "
    out, status = run_wayu('build profile')
    ok = status.success? &&
         out.include?('init-core') && out.include?('interactive shell') &&
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
    # Re-initialize a known-good zsh config so init-core.zsh exists and has
    # phase markers. The test run above may have nuked the file.
    initialize_wayu
    # Also add at least one entry so the generator emits non-empty phases.
    run_wayu("alias add ll 'ls -la'")
    out, status = run_wayu('build profile')
    has_heading = out.include?('Phase breakdown (sorted by time')
    has_sum     = out.match?(/\(sum\)/)
    # Should pick up at least two of the standard init-core.zsh section
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
    print "Test 3: warns when init-core.ext is missing... "
    # Remove the generated init-core so we can observe the warning path.
    Dir.glob("#{@config_dir}/init-core.*").each { |f| File.delete(f) }
    out, status = run_wayu('build profile')
    ok = status.success? && (out.include?('init-core.') && out.downcase.include?('not found'))
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
