#!/usr/bin/env ruby
# Upgrade-path tests (OKAMI-175): config dirs written by older wayu releases
# are upgraded by the current binary without losing anything, and a shell
# that sources init.<ext> afterwards starts clean.
#
# Fixtures (tests/integration/fixtures/upgrade/<version>-<shell>/) are the
# ~/.config/wayu trees the released binaries wrote — built from the git tags
# (`git archive vX.Y.Z src`, `odin build src`) and run in a fresh HOME:
#
#   wayu init --shell SH
#   wayu path add $HOME/tools ; wayu path add "$HOME/bin dir"
#   wayu alias add ll 'ls -la' ; alias add gs 'git status --short'
#   wayu alias add q "echo \"it's quoted\""
#   wayu const add EDITOR nvim ; const add GREETING 'hello world'
#   wayu const add PROJECTS '$HOME/projects'
#
# The HOME path is stored as @HOME@ and the binary path baked into core.<ext>
# as @WAYU_BIN@; *.zwc / lock files are dropped. What each era looks like:
#   3.9.0   legacy path/aliases/constants.<ext>, no wayu.toml
#   3.15.0  wayu.toml with [[paths]] (array-of-tables schema), init-core.<ext>
#           (holds the old `wayu()` shell wrapper), init.<ext> with the
#           `$g_ctx.home` bug
#   4.0.0   [paths] table, otherwise like 3.15.0
#   4.4.5   core/lazy/helpers/path_sync.<ext>, sub-second backup names
#   5.0.0   like 4.4.5 (+ fish)
# Everything is offline: no network, no plugins cloned.

require 'fileutils'
require 'json'
require 'open3'
require_relative 'test_helper'

class UpgradeIntegrationTest
  include WayuTestHelper

  FIXTURES = File.join(__dir__, 'fixtures', 'upgrade')
  # version-shell fixtures whose wayu.toml the current binary reads as-is
  TOML_FIXTURES = %w[4.0.0-zsh 4.0.0-bash 4.4.5-zsh 4.4.5-bash 5.0.0-zsh 5.0.0-bash 5.0.0-fish].freeze

  def initialize
    setup_test_env
  end

  def run
    puts "⬆️  Testing upgrades from older wayu releases..."
    puts
    begin
      build_project
      TOML_FIXTURES.each do |fx|
        if shell_bin(fx.split('-').last).empty?
          puts "Test: upgrade #{fx} via `wayu init`... SKIP (shell not installed)"
          next
        end
        test_init_upgrade(fx)
      end
      %w[4.4.5-zsh 4.4.5-bash 5.0.0-zsh 5.0.0-bash].each { |fx| test_mutation_resyncs_init(fx) }
      %w[3.15.0-zsh 3.15.0-bash].each { |fx| test_array_schema_upgrade(fx) }
      %w[3.9.0-zsh 3.9.0-bash].each { |fx| test_legacy_files_upgrade(fx) }
      test_old_backup_names_listed_and_restorable
      test_old_schema_backups
      test_upgrade_is_idempotent
      test_legacy_plugins_conf
    ensure
      teardown_test_env
    end
    print_summary("upgrade")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def check(ok, detail = nil)
    if ok
      puts "✓"; @passed += 1
    else
      puts "✗"; puts "  #{detail}" if detail; @failed += 1
    end
    ok
  end

  # Fresh HOME holding fixture `fx` as ~/.config/wayu, plus the directories
  # its [paths] point at and a user line in extra.<ext> (user-owned file,
  # must survive the upgrade byte for byte).
  def seed(fx)
    shell = fx.split('-').last
    home = Dir.mktmpdir("up#{fx.delete('.')}", @tmp_home)
    cfg = "#{home}/.config/wayu"
    FileUtils.mkdir_p(File.dirname(cfg))
    FileUtils.cp_r(File.join(FIXTURES, fx), cfg)
    Dir.glob("#{cfg}/**/*", File::FNM_DOTMATCH).each do |f|
      next unless File.file?(f)
      body = File.binread(f)
      next unless body.include?('@HOME@') || body.include?('@WAYU_BIN@')
      File.binwrite(f, body.gsub('@HOME@', home).gsub('@WAYU_BIN@', @wayu_bin))
    end
    FileUtils.mkdir_p(["#{home}/tools", "#{home}/bin dir", "#{home}/projects"])
    extra = "#{cfg}/extra.#{shell}"
    line = shell == 'fish' ? "set -gx FROM_EXTRA kept\n" : "export FROM_EXTRA=kept\n"
    File.write(extra, File.read(extra) + line)
    [home, cfg, shell]
  end

  def wayu(home, shell, *args)
    env = { 'HOME' => home, 'PATH' => '/usr/bin:/bin', 'SHELL' => "/bin/#{shell}",
            'TERM' => 'dumb', 'NO_COLOR' => '1' }.merge(sanitizer_env)
    out, err, st = Open3.capture3(env, @wayu_bin, *args, stdin_data: '', unsetenv_others: true)
    [out.force_encoding('UTF-8'), err.force_encoding('UTF-8'), st]
  end

  def shell_bin(shell)
    `command -v #{shell} 2>/dev/null`.strip
  end

  def fresh_init_template(shell)
    @fresh ||= {}
    @fresh[shell] ||= begin
      home = Dir.mktmpdir('fresh', @tmp_home)
      FileUtils.mkdir_p("#{home}/.config")
      wayu(home, shell, 'init', '--shell', shell)
      File.read("#{home}/.config/wayu/init.#{shell}")
    end
  end

  # Source init.<shell> the way a user's rc file does and report what the
  # shell ended up with. Returns [hash, stderr, status].
  def start_shell(home, shell)
    probe = if shell == 'fish'
              <<~FISH
                source "$HOME/.config/wayu/init.fish"; echo "rc=$status"
                echo "PATH="(string join : $PATH)
                for a in ll gs q; functions -q $a; and echo "fn_$a=yes"; end
                echo "E=$EDITOR"; echo "G=$GREETING"; echo "P=$PROJECTS"; echo "X=$FROM_EXTRA"
                functions -q wayu; and echo "WRAPPER=yes"
                true
              FISH
            else
              <<~SH
                . "$HOME/.config/wayu/init.#{shell}"; echo "rc=$?"
                echo "PATH=$PATH"
                for a in ll gs q; do echo "alias_$a=$(alias $a 2>/dev/null)"; done
                echo "E=$EDITOR"; echo "G=$GREETING"; echo "P=$PROJECTS"; echo "X=$FROM_EXTRA"
                [ "$(type wayu 2>/dev/null | grep -c function)" = 0 ] || echo "WRAPPER=yes"
              SH
            end
    env = { 'HOME' => home, 'PATH' => '/usr/bin:/bin', 'TERM' => 'dumb' }
    out, err, st = Open3.capture3(env, shell_bin(shell), '-c', probe, unsetenv_others: true)
    vals = {}
    out.each_line { |l| k, v = l.chomp.split('=', 2); vals[k] = v if v }
    [vals, err, st]
  end

  # Everything the fixtures' workload created is there after the upgrade.
  def shell_problems(home, shell)
    vals, err, st = start_shell(home, shell)
    probs = []
    probs << "exit=#{st.exitstatus}" unless st.success?
    probs << "rc=#{vals['rc']}" unless vals['rc'] == '0'
    probs << "stderr=#{err.strip[0, 300].inspect}" unless err.strip.empty?
    path = (vals['PATH'] || '').split(':')
    %W[#{home}/tools #{home}/bin\ dir].each { |d| probs << "PATH lacks #{d}" unless path.include?(d) }
    if shell == 'fish'
      %w[ll gs q].each { |a| probs << "no alias #{a}" unless vals["fn_#{a}"] == 'yes' }
    else
      { 'll' => 'ls -la', 'gs' => 'git status --short', 'q' => %q(echo "it's quoted") }.each do |a, v|
        got = vals["alias_#{a}"].to_s.sub(/\Aalias /, '').sub(/\A#{a}=/, '')
        got = got[1..-2].gsub(%q('\''), "'") if got.start_with?("'") && got.end_with?("'")
        probs << "alias #{a}=#{vals["alias_#{a}"].inspect}" unless got == v
      end
    end
    probs << "EDITOR=#{vals['E'].inspect}" unless vals['E'] == 'nvim'
    probs << "GREETING=#{vals['G'].inspect}" unless vals['G'] == 'hello world'
    probs << "PROJECTS=#{vals['P'].inspect}" unless vals['P'] == "#{home}/projects"
    probs << "extra.#{shell} not sourced" unless vals['X'] == 'kept'
    probs << 'old wayu() wrapper still defined' if vals['WRAPPER']
    probs
  end

  # wayu.toml is readable by the current binary and holds every entry.
  def toml_problems(home, shell)
    probs = []
    _, err, st = wayu(home, shell, 'toml', 'validate')
    probs << "toml validate exit=#{st.exitstatus} #{err.strip[0, 200]}" unless st.success?
    out, _, st = wayu(home, shell, 'path', 'list', '--json')
    paths = st.success? ? out : ''
    %W[#{home}/tools #{home}/bin\ dir].each { |d| probs << "path list lacks #{d}" unless paths.include?(d.to_json) }
    out, _, = wayu(home, shell, 'alias', 'list', '--json')
    aliases = ((JSON.parse(out)['aliases'] rescue nil) || []).map { |a| [a['alias'], a['command']] }.to_h
    { 'll' => 'ls -la', 'gs' => 'git status --short', 'q' => %q(echo "it's quoted") }.each do |k, v|
      probs << "alias list #{k}=#{aliases[k].inspect}" unless aliases[k] == v
    end
    %w[EDITOR GREETING PROJECTS].zip(['nvim', 'hello world', '$HOME/projects']).each do |k, v|
      out, _, = wayu(home, shell, 'const', 'get', k)
      probs << "const get #{k}=#{out.strip.inspect}" unless out.strip == v
    end
    probs
  end

  # `wayu init` after upgrading the binary: init.<ext> is rewritten to the
  # current template (old one backed up), wayu.toml is untouched, the shell
  # gets everything.
  def test_init_upgrade(fx)
    print "Test: upgrade #{fx} via `wayu init`... "
    home, cfg, shell = seed(fx)
    toml_before = File.read("#{cfg}/wayu.toml")
    extra_before = File.read("#{cfg}/extra.#{shell}")
    old_init = File.read("#{cfg}/init.#{shell}")
    _, err, st = wayu(home, shell, 'init', '--shell', shell)
    probs = []
    probs << "init exit=#{st.exitstatus} #{err.strip[0, 300]}" unless st.success?
    probs << 'init.<ext> not resynced' unless File.read("#{cfg}/init.#{shell}") == fresh_init_template(shell)
    if old_init != fresh_init_template(shell) &&
       Dir.glob("#{cfg}/backup/init.#{shell}.backup.*").none? { |b| File.read(b) == old_init }
      probs << 'old init.<ext> not backed up'
    end
    probs << 'wayu.toml changed' unless File.read("#{cfg}/wayu.toml") == toml_before
    probs << "extra.#{shell} changed" unless File.read("#{cfg}/extra.#{shell}") == extra_before
    probs << "warning: #{err.strip[0, 200]}" if err.include?('local edits')
    probs.concat(toml_problems(home, shell))
    probs.concat(shell_problems(home, shell))
    check(probs.empty?, probs.join("\n  "))
  end

  # No explicit `wayu init`: the first ordinary write after the upgrade
  # regenerates and resyncs init.<ext>.
  def test_mutation_resyncs_init(fx)
    print "Test: upgrade #{fx} via an ordinary write (alias add)... "
    home, cfg, shell = seed(fx)
    _, err, st = wayu(home, shell, 'alias', 'add', 'zz', 'echo zz')
    probs = []
    probs << "alias add exit=#{st.exitstatus} #{err.strip[0, 300]}" unless st.success?
    probs << 'init.<ext> not resynced' unless File.read("#{cfg}/init.#{shell}") == fresh_init_template(shell)
    probs.concat(toml_problems(home, shell))
    probs.concat(shell_problems(home, shell))
    check(probs.empty?, probs.join("\n  "))
  end

  # 3.x wrote [[paths]] arrays of tables: every command refuses the file
  # (exit 78, pointing at `migrate --schema`) without touching it; after
  # `migrate --schema` + `init` everything is there.
  def test_array_schema_upgrade(fx)
    print "Test: upgrade #{fx} ([[paths]] schema) via migrate --schema + init... "
    home, cfg, shell = seed(fx)
    toml_before = File.read("#{cfg}/wayu.toml")
    probs = []
    _, err, st = wayu(home, shell, 'init', '--shell', shell)
    probs << "init on old schema exit=#{st.exitstatus}" unless st.exitstatus == 78
    probs << 'no migrate --schema hint' unless err.include?('migrate --schema')
    probs << 'wayu.toml touched before migrate' unless File.read("#{cfg}/wayu.toml") == toml_before
    _, err, st = wayu(home, shell, 'migrate', '--schema')
    probs << "migrate --schema exit=#{st.exitstatus} #{err.strip[0, 300]}" unless st.success?
    probs << 'pre-migrate wayu.toml not backed up' if Dir.glob("#{cfg}/backup/wayu.toml.backup.*").none? { |b| File.read(b) == toml_before }
    _, err, st = wayu(home, shell, 'init', '--shell', shell)
    probs << "init exit=#{st.exitstatus} #{err.strip[0, 300]}" unless st.success?
    probs << 'init.<ext> not resynced' unless File.read("#{cfg}/init.#{shell}") == fresh_init_template(shell)
    probs.concat(toml_problems(home, shell))
    probs.concat(shell_problems(home, shell))
    check(probs.empty?, probs.join("\n  "))
  end

  # Pre-3.10: no wayu.toml, entries live in path/aliases/constants.<ext>.
  # `wayu migrate` imports them; `init` then wires the shell. 3.9.0 stored
  # `const add PROJECTS '$HOME/projects'` as `export PROJECTS="\$HOME/..."`
  # (a literal `$`), which wayu.toml can't express: migrate names that line,
  # imports nothing and archives nothing until the user decides.
  def test_legacy_files_upgrade(fx)
    print "Test: upgrade #{fx} (legacy shell files) via migrate + init... "
    home, cfg, shell = seed(fx)
    probs = []
    consts = "#{cfg}/constants.#{shell}"
    legacy = %W[path aliases constants].to_h { |b| ["#{cfg}/#{b}.#{shell}", File.read("#{cfg}/#{b}.#{shell}")] }
    _, err, st = wayu(home, shell, 'migrate')
    probs << "migrate of literal-$ line exit=#{st.exitstatus}" unless st.exitstatus == 65
    lineno = File.readlines(consts).index { |l| l.include?('PROJECTS') }.to_i + 1
    probs << "refusal does not name constants.#{shell}:#{lineno}" unless err.include?("constants.#{shell}:#{lineno}")
    probs << 'wayu.toml written by a refused migrate' if File.exist?("#{cfg}/wayu.toml")
    legacy.each { |f, body| probs << "#{File.basename(f)} touched by a refused migrate" unless File.exist?(f) && File.read(f) == body }
    # The user keeps the expansion (drops the backslash) and migrates again.
    File.write(consts, File.read(consts).sub('"\\$HOME/projects"', '"$HOME/projects"'))
    _, err, st = wayu(home, shell, 'migrate')
    probs << "migrate exit=#{st.exitstatus} #{err.strip[0, 300]}" unless st.success?
    _, err, st = wayu(home, shell, 'init', '--shell', shell)
    probs << "init exit=#{st.exitstatus} #{err.strip[0, 300]}" unless st.success?
    probs << 'init.<ext> not resynced' unless File.read("#{cfg}/init.#{shell}") == fresh_init_template(shell)
    probs.concat(toml_problems(home, shell))
    probs.concat(shell_problems(home, shell))
    check(probs.empty?, probs.join("\n  "))
  end

  def toml_backups(home, shell)
    out, _, st = wayu(home, shell, 'backup', 'list', '--json')
    groups = (JSON.parse(out)['backups'] rescue nil) || []
    [groups.select { |g| g['file'] == 'wayu.toml' }.flat_map { |g| g['entries'] }, st]
  end

  # 4.4.x named backups with sub-second timestamps: all are listed, and
  # `backup restore toml N` restores the oldest exactly.
  def test_old_backup_names_listed_and_restorable
    print "Test: 4.4.5 backups listed and restorable... "
    home, cfg, shell = seed('4.4.5-zsh')
    old = Dir.glob("#{cfg}/backup/wayu.toml.backup.*")
    entries, st = toml_backups(home, shell)
    probs = []
    probs << "backup list exit=#{st.exitstatus}" unless st.success?
    probs << "listed #{entries.size} of #{old.size}" unless entries.map { |e| e['path'] }.sort == old.sort
    oldest = entries.max_by { |e| e['index'].to_i }
    if oldest
      want = File.read(oldest['path'])
      _, err, st = wayu(home, shell, 'backup', 'restore', 'toml', oldest['index'].to_s, '--yes')
      probs << "restore exit=#{st.exitstatus} #{err.strip[0, 200]}" unless st.success?
      probs << 'restored content differs' unless File.read("#{cfg}/wayu.toml") == want
    end
    check(probs.empty?, probs.join("\n  "))
  end

  # 3.x backups (second-resolution names, [[paths]] schema) are listed even
  # while wayu.toml itself is still on the old schema (backup is the
  # recovery tool), and are never restored over a migrated wayu.toml: that
  # left a file every other command refuses, including the documented undo
  # `backup restore toml 1`.
  def test_old_schema_backups
    print "Test: 3.15.0 backups listed before migrate, not restored after... "
    home, cfg, shell = seed('3.15.0-zsh')
    old = Dir.glob("#{cfg}/backup/wayu.toml.backup.*")
    entries, st = toml_backups(home, shell)
    probs = []
    probs << "backup list on old schema exit=#{st.exitstatus}" unless st.success?
    probs << "listed #{entries.size} of #{old.size}" unless entries.map { |e| e['path'] }.sort == old.sort
    wayu(home, shell, 'migrate', '--schema')
    migrated = File.read("#{cfg}/wayu.toml")
    entries, = toml_backups(home, shell)
    oldest = entries.max_by { |e| e['index'].to_i }
    _, err, st = wayu(home, shell, 'backup', 'restore', 'toml', oldest['index'].to_s, '--yes')
    probs << "restore of [[paths]] backup exit=#{st.exitstatus}" if st.success?
    probs << "no schema reason: #{err.strip[0, 200]}" unless err.include?('obsolete') && err.include?('migrate --schema')
    probs << 'wayu.toml changed by refused restore' unless File.read("#{cfg}/wayu.toml") == migrated
    _, _, st = wayu(home, shell, 'alias', 'list')
    probs << "alias list after refused restore exit=#{st.exitstatus}" unless st.success?
    check(probs.empty?, probs.join("\n  "))
  end

  # Running the upgrade twice changes nothing the second time and takes no
  # further backups of init.<ext>.
  def test_upgrade_is_idempotent
    print "Test: second `wayu init` after an upgrade is a no-op... "
    home, cfg, shell = seed('4.4.5-zsh')
    wayu(home, shell, 'init', '--shell', shell)
    snap = ->() { Dir.glob("#{cfg}/**/*").reject { |f| f.end_with?('.zwc') || File.directory?(f) || f.include?('/.') }.sort.to_h { |f| [f, File.binread(f)] } }
    before = snap.call
    _, err, st = wayu(home, shell, 'init', '--shell', shell)
    after = snap.call
    changed = (before.keys | after.keys).reject { |k| before[k] == after[k] }
    check(st.success? && changed.empty?, "exit=#{st.exitstatus} changed=#{changed.map { |c| c.sub(cfg, '') }} #{err.strip[0, 200]}")
  end

  # plugins.conf (`name|url|enabled|shell`, pre-plugins.json) is converted
  # on first use: entries kept (incl. disabled state), old file kept as
  # plugins.conf.backup.
  def test_legacy_plugins_conf
    print "Test: legacy plugins.conf is migrated to plugins.json... "
    home, cfg, shell = seed('4.4.5-zsh')
    File.write("#{cfg}/plugins.conf", <<~CONF)
      # wayu plugins
      zsh-autosuggestions|https://github.com/zsh-users/zsh-autosuggestions.git|true|zsh
      zsh-syntax-highlighting|https://github.com/zsh-users/zsh-syntax-highlighting.git|false|both
    CONF
    %w[zsh-autosuggestions zsh-syntax-highlighting].each do |p|
      FileUtils.mkdir_p("#{cfg}/plugins/#{p}")
      File.write("#{cfg}/plugins/#{p}/#{p}.plugin.zsh", "# #{p}\n")
    end
    out, err, st = wayu(home, shell, 'plugin', 'list', '--json')
    probs = []
    probs << "plugin list exit=#{st.exitstatus} #{err.strip[0, 300]}" unless st.success?
    probs << 'plugins.conf not kept as .backup' unless File.exist?("#{cfg}/plugins.conf.backup") && !File.exist?("#{cfg}/plugins.conf")
    json = File.exist?("#{cfg}/plugins.json") ? File.read("#{cfg}/plugins.json") : ''
    probs << 'plugins.json missing' if json.empty?
    listed = (JSON.parse(out[out.index('{')..]) rescue {})['plugins'] || []
    by_name = listed.to_h { |p| [p['name'], p] }
    probs << "autosuggestions=#{by_name['zsh-autosuggestions'].inspect}" unless by_name.dig('zsh-autosuggestions', 'enabled') == true
    probs << "syntax-highlighting=#{by_name['zsh-syntax-highlighting'].inspect}" unless by_name.dig('zsh-syntax-highlighting', 'enabled') == false
    check(probs.empty?, probs.join("\n  "))
  end
end

UpgradeIntegrationTest.new.run if __FILE__ == $0
