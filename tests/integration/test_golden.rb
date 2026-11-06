#!/usr/bin/env ruby
# Component visual regression: renders each TUI component headlessly
# (`wayu -c=<component> --test ...`) and compares against tests/golden/*.txt.
# Cases (component + args) live in tests/golden/cases.txt; every golden file
# must have exactly one case so goldens can't silently go unchecked.

require 'open3'
require 'shellwords'
require_relative 'test_helper'

class GoldenIntegrationTest
  include WayuTestHelper

  GOLDEN_DIR = File.expand_path('../golden', __dir__)
  CASES_FILE = File.join(GOLDEN_DIR, 'cases.txt')

  def initialize
    setup_test_env
  end

  def run
    puts "🖼️  Testing component goldens..."
    puts
    begin
      build_project
      cases = load_cases
      test_every_golden_has_a_case(cases)
      cases.each { |name, words| test_case(name, words) }
    ensure
      teardown_test_env
    end
    print_summary("golden")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def load_cases
    File.readlines(CASES_FILE).map do |line|
      line = line.strip
      next if line.empty? || line.start_with?('#')
      name, rest = line.split(/\s+/, 2)
      [name, Shellwords.split(rest.to_s)]
    end.compact
  end

  def check(ok, detail = '')
    if ok
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  #{detail}" unless detail.empty?
      @failed += 1
    end
  end

  def test_every_golden_has_a_case(cases)
    print "Every golden file has exactly one case... "
    goldens = Dir.glob(File.join(GOLDEN_DIR, '*.txt')).map { |f| File.basename(f, '.txt') } - ['cases']
    names = cases.map(&:first)
    missing = goldens - names
    orphan = names - goldens
    dupes = names.select { |n| names.count(n) > 1 }.uniq
    check(missing.empty? && orphan.empty? && dupes.empty?,
          "missing cases: #{missing} / cases without golden: #{orphan} / duplicates: #{dupes}")
  end

  def test_case(name, words)
    print "Golden #{name}... "
    m = name.match(/_(\d+)x(\d+)\z/)
    return check(false, "name must end in _<W>x<H>") unless m

    component, *extra = words
    argv = [@wayu_bin, "-c=#{component}", '--test', "width=#{m[1]}", "height=#{m[2]}", *extra]
    env = ENV.to_h.merge('HOME' => @tmp_home, 'NO_COLOR' => '1')
    out, status = Open3.capture2e(env, *argv, chdir: File.expand_path('../..', __dir__))
    check(status.success? && out.include?('MATCH') && !out.include?('MISMATCH'), out.lines.first(12).join)
  end
end

GoldenIntegrationTest.new.run if __FILE__ == $PROGRAM_NAME
