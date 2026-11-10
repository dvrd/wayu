#!/usr/bin/env ruby
# Release tooling (.github/scripts, cliff.toml): the Homebrew formula
# (OKAMI-295: caveats name the data-dir init file; OKAMI-294: macOS floor),
# the macOS minimum version of bin/wayu (OKAMI-294), and the release notes
# (OKAMI-319: full BREAKING CHANGE footers; upgrade notes from UPGRADING.md).

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
      test_release_notes_use_upgrading_section
      test_release_notes_without_section
      test_release_notes_without_cliff_upgrade_notes
      test_upgrading_version_rename
      test_cliff_keeps_whole_breaking_footer
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

  CLIFF_NOTES = <<~MD
    ## [9.0.0] - 2026-01-01

    ### ⚠ Upgrade notes

    - **shell**: Cut off footer from the
    commit

    ### Added

    - **x**: A feature

    ### Fixed

    - **y**: A fix
  MD

  UPGRADING = <<~MD
    # Upgrading wayu

    ## Unreleased

    - Next thing.

    ## 9.0.0

    **Data dir moves**

    - The full, curated note.

    ## 8.0.0

    - Older note.
  MD

  def release_notes(version, cliff, upgrading)
    Dir.mktmpdir('wayu_notes_') do |dir|
      File.write(File.join(dir, 'cliff.md'), cliff)
      File.write(File.join(dir, 'UPGRADING.md'), upgrading)
      Open3.capture3(File.join(SCRIPTS, 'release-notes.sh'), version,
                     File.join(dir, 'cliff.md'), File.join(dir, 'UPGRADING.md'))
    end
  end

  def test_release_notes_use_upgrading_section
    print "Test: release notes take the upgrade notes from UPGRADING.md... "
    out, err, st = release_notes('v9.0.0', CLIFF_NOTES, UPGRADING)
    ok = st.success? &&
         out.include?("### ⚠ Upgrade notes\n\n**Data dir moves**\n\n- The full, curated note.") &&
         out.include?('UPGRADING.md#900') &&
         !out.include?('Cut off footer') && !out.include?('Older note') && !out.include?('Next thing') &&
         out.include?("### Added\n\n- **x**: A feature") && out.include?("### Fixed\n\n- **y**: A fix") &&
         out.index('### ⚠ Upgrade notes') < out.index('### Added')
    check(ok, "#{err}\n#{out}")
  end

  def test_release_notes_without_section
    print "Test: release notes keep git-cliff's notes without an UPGRADING section... "
    out, err, st = release_notes('v9.1.0', CLIFF_NOTES, UPGRADING)
    check(st.success? && out == CLIFF_NOTES, "#{err}\n#{out}")
  end

  def test_release_notes_without_cliff_upgrade_notes
    print "Test: release notes add the UPGRADING section when no commit was breaking... "
    cliff = CLIFF_NOTES.sub(/### ⚠ Upgrade notes.*?(?=### Added)/m, '')
    out, err, st = release_notes('v9.0.0', cliff, UPGRADING)
    ok = st.success? && out.include?('The full, curated note.') &&
         out.index('### ⚠ Upgrade notes') < out.index('### Added')
    check(ok, "#{err}\n#{out}")
  end

  def test_upgrading_version_rename
    print "Test: upgrading-version.sh names the Unreleased section after the release... "
    Dir.mktmpdir('wayu_upg_') do |dir|
      path = File.join(dir, 'UPGRADING.md')
      File.write(path, UPGRADING)
      _, err, st = Open3.capture3(File.join(SCRIPTS, 'upgrading-version.sh'), 'v9.1.0', path)
      text = File.read(path)
      ok = st.success? && text.include?("## 9.1.0\n\n- Next thing.") && !text.include?('## Unreleased')
      # A second run (re-run of the release) changes nothing.
      _, _, st2 = Open3.capture3(File.join(SCRIPTS, 'upgrading-version.sh'), 'v9.1.0', path)
      check(ok && st2.success? && File.read(path) == text, "#{err}\n#{text}")
    end
  end

  # git-cliff's parsed breaking_description stops at a wrapped line that
  # looks like a footer token ("`$NAME:x` ..."); the template must keep the
  # whole footer.
  def test_cliff_keeps_whole_breaking_footer
    _, st = Open3.capture2e('git', 'cliff', '--version')
    unless st.success?
      puts "Test: cliff.toml keeps whole BREAKING CHANGE footers... skipped (git-cliff not installed)"
      return
    end
    print "Test: cliff.toml keeps whole BREAKING CHANGE footers... "
    Dir.mktmpdir('wayu_cliff_') do |dir|
      git = ->(*args) { Open3.capture2e('git', '-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@t',
                                        '-c', 'commit.gpgsign=false', '-c', 'tag.gpgsign=false', *args) }
      git.call('init', '-q')
      File.write(File.join(dir, 'a'), '1')
      git.call('add', 'a')
      git.call('commit', '-q', '-m', 'feat: first')
      git.call('tag', 'v1.0.0')
      File.write(File.join(dir, 'a'), '2')
      git.call('add', 'a')
      msg = "fix(shell)!: literal dollars\n\nBody text.\n\n" \
            "BREAKING CHANGE: values are literal; in zsh\n`$NAME:x` no longer applies modifiers;\n" \
            "fish keeps `${NAME:-x}` literal. END-OF-FOOTER."
      git.call('commit', '-q', '-m', msg)
      out, st2 = Open3.capture2e('git', 'cliff', '--config', File.join(ROOT, 'cliff.toml'),
                                 '--unreleased', '--strip', 'all', chdir: dir)
      ok = st2.success? && out.include?("- **shell**: Values are literal; in zsh\n`$NAME:x` no longer applies modifiers;") &&
           out.include?('END-OF-FOOTER.')
      check(ok, out)
    end
  end
end

ReleaseIntegrationTest.new.run if __FILE__ == $PROGRAM_NAME
