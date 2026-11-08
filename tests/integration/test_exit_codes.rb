#!/usr/bin/env ruby
# Documented exit codes (OKAMI-190): runs every row of the "Exit code
# examples" table in docs/cli.md against a freshly initialized config and
# checks the exit status, plus the cases the doc describes in prose
# (commands before `wayu init`, an unparsable wayu.toml).

require 'fileutils'
require 'tmpdir'
require_relative 'test_helper'

class ExitCodesIntegrationTest
  include WayuTestHelper

  DOC = File.expand_path('../../docs/cli.md', __dir__)
  ROW = /^\| `wayu (?<args>[^`]+)` \| (?<code>\d+) \|$/

  def initialize
    setup_test_env
  end

  def run
    puts "Testing documented exit codes (docs/cli.md)..."
    puts

    begin
      build_project
      initialize_wayu

      cases = documented_cases
      test_table_present(cases)
      cases.each { |args, code| test_case(args, code) }
      test_not_initialized
      test_unparsable_toml
    ensure
      teardown_test_env
    end

    print_summary("exit code")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def check(ok, detail)
    if ok
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  #{detail}"
      @failed += 1
    end
  end

  # Rows of the table under "### Exit code examples" (up to the next heading).
  def documented_cases
    text = File.read(DOC)
    section = text[/^### Exit code examples\n(.*?)(?=^#)/m, 1] || ''
    section.lines.map { |l| (m = ROW.match(l.chomp)) && [m[:args], m[:code].to_i] }.compact
  end

  def test_table_present(cases)
    print "Test: docs/cli.md lists exit code examples for 0, 64, 65, 66, 78... "
    codes = cases.map(&:last).uniq
    missing = [0, 64, 65, 66, 78] - codes
    check(cases.size >= 10 && missing.empty?, "found #{cases.size} rows, missing codes #{missing}")
  end

  def test_case(args, code)
    print "Test: wayu #{args} → #{code}... "
    output, status = run_wayu(args)
    check(status.exitstatus == code, "exit #{status.exitstatus}, expected #{code}\n  #{output.strip.lines.first(3).join('  ')}")
  end

  # A separate HOME without `wayu init`.
  def with_home(home)
    saved = @tmp_home
    @tmp_home = home
    yield
  ensure
    @tmp_home = saved
  end

  def test_not_initialized
    home = Dir.mktmpdir('wayu_exit_', '/tmp')
    begin
      with_home(home) do
        ['path list', 'alias list', 'const list'].each do |args|
          print "Test: wayu #{args} before init → 78... "
          output, status = run_wayu(args)
          check(status.exitstatus == 78, "exit #{status.exitstatus}: #{output.strip[0, 200]}")
        end
      end
    ensure
      FileUtils.rm_rf(home)
    end
  end

  def test_unparsable_toml
    toml = "#{@config_dir}/wayu.toml"
    saved = File.read(toml)
    File.write(toml, saved + "\n[aliases]\nll = ls\n")
    begin
      print "Test: wayu doctor with an unparsable wayu.toml → 78... "
      output, status = run_wayu('doctor')
      check(status.exitstatus == 78, "exit #{status.exitstatus}: #{output.strip[0, 200]}")
      print "Test: wayu toml validate with an unparsable wayu.toml → 65... "
      output, status = run_wayu('toml validate')
      check(status.exitstatus == 65, "exit #{status.exitstatus}: #{output.strip[0, 200]}")
    ensure
      File.write(toml, saved)
    end
  end
end

ExitCodesIntegrationTest.new.run if __FILE__ == $PROGRAM_NAME
