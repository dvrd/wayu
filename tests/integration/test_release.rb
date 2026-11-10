#!/usr/bin/env ruby
# Release tooling (.github/scripts, cliff.toml): the Homebrew formula
# (OKAMI-295: caveats name the data-dir init file; OKAMI-294: macOS floor)
# and the macOS minimum version of bin/wayu (OKAMI-294).

require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative 'test_helper'

class ReleaseIntegrationTest
  include WayuTestHelper

  ROOT = File.expand_path('../..', __dir__)
  SCRIPTS = File.join(ROOT, '.github', 'scripts')
  SHA = 'a' * 64

  def initialize
    setup_test_env
  end

  def run
    puts "Testing release tooling..."
    puts

    begin
      test_formula_caveats
      test_formula_macos_floor
      test_macos_minos
    ensure
      teardown_test_env
    end

    print_summary("release")
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

  def formula
    @formula ||= begin
      out, err, st = Open3.capture3(File.join(SCRIPTS, 'homebrew-formula.sh'), 'v1.2.3', SHA, SHA)
      raise "homebrew-formula.sh failed: #{err}" unless st.success?
      out
    end
  end

  # The rc lines README's "Shell setup" table tells users to add.
  def readme_source_line(ext)
    readme = File.read(File.join(ROOT, 'README.md'))
    readme[%r{`(source "\$\{WAYU_DATA_DIR:-[^`]*/init\.#{ext}")`}, 1]
  end

  def test_formula_caveats
    print "Test: formula caveats source the data-dir init file, not ~/.config/wayu... "
    zsh = readme_source_line('zsh')
    bash = readme_source_line('bash')
    ok = !formula.include?('.config/wayu/init') && zsh && bash &&
         formula.include?(zsh) && formula.include?(bash)
    check(ok, "zsh=#{zsh.inspect} bash=#{bash.inspect}\n#{formula[/def caveats.*?end/m]}")

    print "Test: formula is valid Ruby... "
    Dir.mktmpdir('wayu_formula_') do |dir|
      path = File.join(dir, 'wayu.rb')
      File.write(path, formula)
      out, st = Open3.capture2e('ruby', '-c', path)
      check(st.success?, out)
    end
  end

  def test_formula_macos_floor
    print "Test: formula requires the macOS floor (depends_on macos)... "
    floor = File.read(File.join(ROOT, '.github', 'macos-minimum-version')).strip
    names = { '11' => 'big_sur', '12' => 'monterey', '13' => 'ventura', '14' => 'sonoma', '15' => 'sequoia', '26' => 'tahoe' }
    want = "depends_on macos: :#{names[floor.split('.').first]}"
    check(formula.include?(want), "floor #{floor}: missing #{want.inspect}")
  end

  def test_macos_minos
    return unless RUBY_PLATFORM.include?('darwin')
    return if ENV['WAYU_BIN'] # another build (e.g. ASan); ./build_it build sets the floor
    build_project
    print "Test: bin/wayu runs on the macOS floor (otool minos)... "
    out, st = Open3.capture2e(File.join(SCRIPTS, 'check-macos-minos.sh'), @wayu_bin)
    check(st.success?, out)
  end
end

ReleaseIntegrationTest.new.run if __FILE__ == $PROGRAM_NAME
