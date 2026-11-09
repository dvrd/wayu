#!/usr/bin/env ruby
# Integration tests for `wayu optimize` (OKAMI-373) and the startup-file
# notice / auto_optimize / doctor check (OKAMI-374).
#
# Each test builds its own HOME (ZDOTDIR = HOME) with wayu loaded from
# .zshenv and installer lines appended to .zshrc, like a real machine. A fake
# `fakegen` binary stands in for tools whose completion/init output gets
# sourced; `~/.grok/completions/zsh/_grok` for a completion dir.

require 'open3'
require 'fileutils'
require_relative 'test_helper'

class OptimizeIntegrationTest
  include WayuTestHelper

  LOADER = "source \"${WAYU_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/wayu}/init.zsh\"\n"

  ZSHRC = <<~'RC'
    # installers appended these
    fpath=(~/.grok/completions/zsh $fpath)
    autoload -Uz compinit && compinit
    export PATH="$HOME/.grok/bin:$PATH"
    source <(fakegen completion zsh)
    eval "$(fakegen init zsh)"
    alias ll='ls -la'
    export EDITOR=nvim
    export NVM_DIR="$HOME/.nvm"
    export OPENAI_API_KEY=sk-testabcdefghijklmnopqrstuvwxyz012345
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    if [[ -n $ZSH_VERSION ]]; then
      alias inside_if=yes
    fi
  RC

  # Shell state compared before/after: PATH, fpath, aliases, the constants
  # and the generators' effects, the grok completion.
  ZSH_PROBE = 'print -r -- "PATH=$PATH"; print -r -- "FPATH=${(j.:.)fpath}"; alias | sort; ' \
              'for v in EDITOR NVM_DIR OPENAI_API_KEY FAKEGEN_INIT fakegen_comp; do print -r -- "$v=${(P)v-unset}"; done; ' \
              'print -r -- "comp_grok=${_comps[grok]-none}"; whence -w fg_fn'

  def initialize
    setup_test_env
  end

  def run
    puts "🧹 Testing wayu optimize..."
    puts

    begin
      build_project
      test_preview_requires_yes
      test_apply_equivalent_and_idempotent
      test_backup_restore_undoes
      test_bash_generator_and_alias
      test_prompt_notice_once
      test_auto_optimize
      test_doctor_check_and_fix
      test_config_scan_zdotdir_and_markers
    ensure
      teardown_test_env
    end

    print_summary("optimize")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def check(label, ok, detail = '')
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

  def make_home(name, shell: 'zsh')
    home = "#{@tmp_home}/#{name}"
    FileUtils.rm_rf(home)
    FileUtils.mkdir_p(["#{home}/.config", "#{home}/fbin", "#{home}/.grok/completions/zsh", "#{home}/.grok/bin", "#{home}/.nvm"])
    File.write("#{home}/fbin/fakegen", <<~'SH')
      #!/bin/sh
      case "$1" in
        completion) echo 'fakegen_comp=1'; echo "alias fgc='echo comp'" ;;
        init) echo 'export FAKEGEN_INIT=1'; echo 'fg_fn() { echo fn; }' ;;
      esac
    SH
    File.chmod(0o755, "#{home}/fbin/fakegen")
    File.write("#{home}/.grok/completions/zsh/_grok", "#compdef grok\n_arguments '*:file:_files'\n")
    env = { 'HOME' => home, 'SHELL' => "/bin/#{shell}", 'PATH' => "#{home}/fbin:/usr/bin:/bin:/usr/sbin:/sbin",
            'ZDOTDIR' => (shell == 'zsh' ? home : nil), 'WAYU_CONFIG' => nil, 'WAYU_CONFIG_DIR' => nil,
            'WAYU_DATA_DIR' => nil, 'XDG_CONFIG_HOME' => nil, 'XDG_DATA_HOME' => nil, 'XDG_CACHE_HOME' => nil }
    Open3.capture3(env, @wayu_bin, 'init', '--shell', shell, stdin_data: '')
    File.open("#{home}/.config/wayu/wayu.toml", 'a') { |f| f.puts "\n[secrets]\nbackend = \"file\"" }
    if shell == 'zsh'
      File.write("#{home}/.zshenv", LOADER)
      File.write("#{home}/.zshrc", ZSHRC)
    end
    [home, env]
  end

  def wayu(env, *args)
    out, err, st = Open3.capture3(env, @wayu_bin, *args, stdin_data: '')
    [out + err, st]
  end

  def zsh_probe(env, probe = ZSH_PROBE)
    out, err, = Open3.capture3(env, 'zsh', '-i', '-c', probe, stdin_data: '')
    [out, err]
  end

  def test_preview_requires_yes
    home, env = make_home('preview')
    out, st = wayu(env, 'optimize')
    check('Test 1: optimize without --yes shows the diff and exits 64',
          st.exitstatus == 64 && out.include?('-source <(fakegen completion zsh)') && out.include?('--yes') &&
            File.read("#{home}/.zshrc") == ZSHRC, "exit=#{st.exitstatus} out=#{out[0, 600]}")
    out, st = wayu(env, 'optimize', '--dry-run')
    check('Test 2: --dry-run prints the plan, exits 0, writes nothing',
          st.success? && out.include?('generator  fakegen init zsh') && out.include?('compinit   removed') &&
            File.read("#{home}/.zshrc") == ZSHRC && !File.exist?("#{home}/.local/share/wayu/entries.json") ||
            (st.success? && File.read("#{home}/.zshrc") == ZSHRC && !File.read("#{home}/.local/share/wayu/entries.json").include?('fakegen')),
          "exit=#{st.exitstatus} out=#{out[0, 600]}")
    out, st = wayu(env, 'optimize', '--check')
    check('Test 3: --check lists the lines and exits 1', st.exitstatus == 1 && out.include?('9 lines can be optimized'),
          "exit=#{st.exitstatus} out=#{out}")
  end

  def test_apply_equivalent_and_idempotent
    home, env = make_home('apply')
    before, berr = zsh_probe(env)
    out, st = wayu(env, 'optimize', '--yes')
    rc = File.read("#{home}/.zshrc")
    check('Test 4: --yes moves 9 lines and keeps the rest',
          st.success? && out.include?('Moved 9 lines') && rc.include?('[ -s "$NVM_DIR/nvm.sh" ]') &&
            rc.include?('alias inside_if=yes') && !rc.include?('fakegen') && !rc.include?('compinit'),
          "exit=#{st.exitstatus} out=#{out[0, 500]} rc=#{rc}")
    store = JSON.parse(File.read("#{home}/.local/share/wayu/entries.json"))
    env_names = store['env'].map { |e| e['name'] }
    secret = store['env'].find { |e| e['name'] == 'OPENAI_API_KEY' }
    check('Test 5: entries.json gets paths, fpath, generators, alias, constants (API key encrypted)',
          store['paths'].map { |p| p['dir'] } == ['$HOME/.grok/bin'] && store['fpath'] == ['$HOME/.grok/completions/zsh'] &&
            store['generators'].map { |g| g['args'] } == ['completion zsh', 'init zsh'] &&
            store['aliases'] == [{ 'name' => 'll', 'value' => 'ls -la' }] && env_names == %w[EDITOR NVM_DIR OPENAI_API_KEY] &&
            secret && secret['secret'] == true && !secret.key?('value') &&
            !File.read("#{home}/.local/share/wayu/entries.json").include?('sk-test'),
          JSON.pretty_generate(store))
    after, aerr = zsh_probe(env)
    check('Test 6: startup state is identical (PATH, fpath, aliases, env, generators, completions)',
          before == after && before.include?('comp_grok=_grok') && before.include?('FAKEGEN_INIT=1') &&
            before.include?('OPENAI_API_KEY=sk-test') && before.include?('fg_fn: function'),
          "before=#{before}\nafter=#{after}\nberr=#{berr[0, 300]}\naerr=#{aerr[0, 300]}")
    out, st = wayu(env, 'optimize', '--yes')
    out2, st2 = wayu(env, 'optimize', '--check')
    check('Test 7: second run changes nothing (exit 0); --check exits 0',
          st.success? && out.include?('Nothing to optimize') && File.read("#{home}/.zshrc") == rc && st2.exitstatus == 0,
          "exit=#{st.exitstatus}/#{st2.exitstatus} out=#{out} #{out2}")
  end

  def test_backup_restore_undoes
    home, env = make_home('restore')
    wayu(env, 'optimize', '--yes')
    out, st = wayu(env, 'backup', 'restore', '.zshrc', '--yes')
    check('Test 8: wayu backup restore .zshrc brings the original file back',
          st.success? && File.read("#{home}/.zshrc") == ZSHRC, "exit=#{st.exitstatus} out=#{out}")
  end

  def test_bash_generator_and_alias
    home, env = make_home('bash', shell: 'bash')
    rc = "#{LOADER.sub('init.zsh', 'init.bash')}source <(fakegen completion bash)\nalias ll='ls -la'\nexport PATH=\"$PATH:$HOME/.grok/bin\"\n"
    File.write("#{home}/.bashrc", rc)
    probe = 'echo "PATH=$PATH"; alias; echo "fakegen_comp=${fakegen_comp-unset}"'
    before, = Open3.capture3(env, 'bash', '-i', '-c', probe, stdin_data: '')
    out, st = wayu(env, 'optimize', '--yes', '--shell', 'bash')
    after, = Open3.capture3(env, 'bash', '-i', '-c', probe, stdin_data: '')
    left = File.read("#{home}/.bashrc")
    # bash 3.2 (macOS /bin/bash) can't `source <(...)`, so `before` may lack
    # the generator's effects; after the move it works in every bash.
    check('Test 9: bash: generator, alias and appended PATH dir move into wayu',
          st.success? && left == LOADER.sub('init.zsh', 'init.bash') && before.include?("alias ll='ls -la'") &&
            after.include?("alias ll='ls -la'") && after.include?('fakegen_comp=1') && after.include?("alias fgc='echo comp'") &&
            after.include?("#{home}/.grok/bin"),
          "exit=#{st.exitstatus} out=#{out[0, 400]}\nbefore=#{before}\nafter=#{after}\nrc=#{left}")
  end

  # The prompt hook prints the notice once per change, without forking when
  # nothing changed.
  def test_prompt_notice_once
    home, env = make_home('notice')
    File.write("#{home}/.zshrc", "alias kept_one=x\n")
    wayu(env, 'optimize', '--yes') # moves it, writes the stamp
    hook = 'for f in $precmd_functions; do $f; done'
    _, err1 = zsh_probe(env, hook)
    stamp = "#{home}/.local/share/wayu/rc_check.stamp"
    past = Time.now - 60
    File.utime(past, past, stamp) if File.exist?(stamp)
    File.open("#{home}/.zshrc", 'a') { |f| f.puts "source <(fakegen completion zsh)\nalias newer=yes" }
    _, err2 = zsh_probe(env, hook)
    _, err3 = zsh_probe(env, hook)
    check('Test 10: notice printed once after the rc file changed',
          !err1.include?('can be optimized') &&
            err2.include?('wayu: ~/.zshrc changed: 2 lines can be optimized (wayu optimize)') &&
            !err3.include?('can be optimized') && File.read("#{home}/.zshrc").include?('alias newer=yes'),
          "err1=#{err1[0, 300]}\nerr2=#{err2[0, 300]}\nerr3=#{err3[0, 300]}")
  end

  def test_auto_optimize
    home, env = make_home('auto')
    File.open("#{home}/.config/wayu/wayu.toml", 'a') { |f| f.puts "\n[settings]\nauto_optimize = true" }
    File.write("#{home}/.zshrc", "alias auto_one=yes\n")
    _, err = zsh_probe(env, 'for f in $precmd_functions; do $f; done')
    ef = "#{home}/.local/share/wayu/entries.json"
    store = File.exist?(ef) ? JSON.parse(File.read(ef)) : { 'aliases' => [] }
    backups = Dir.glob("#{home}/.local/share/wayu/backup/.zshrc.backup.*")
    check('Test 11: auto_optimize moves the lines (with a backup) and says so',
          err.include?('auto_optimize moved 1 line') && File.read("#{home}/.zshrc").strip.empty? &&
            store['aliases'].any? { |a| a['name'] == 'auto_one' } && backups.size == 1,
          "err=#{err[0, 400]} rc=#{File.read("#{home}/.zshrc")} backups=#{backups}")
    out, st = wayu(env, 'toml', 'validate')
    check('Test 12: [settings] auto_optimize is a known key', st.success? && !out.include?('auto_optimize'), out)
  end

  def test_doctor_check_and_fix
    home, env = make_home('doctor')
    out, = wayu(env, 'doctor', '--json')
    checks = JSON.parse(out[out.index('{')..])['checks'] rescue []
    c = checks.find { |x| x['name'] == 'startup files' }
    check('Test 13: doctor reports the optimizable lines with a cost estimate',
          c && c['status'] == 'warning' && c['fixable'] == true && c['message'].include?('~250 ms') &&
            c['message'].include?('fakegen completion zsh'),
          c.inspect)
    out, = wayu(env, 'doctor', '--fix', '--yes')
    check('Test 14: doctor --fix --yes runs optimize',
          out.include?('moved 9 lines into wayu') && !File.read("#{home}/.zshrc").include?('fakegen'), out[-800..] || out)
  end

  # Audit fixes in `config scan`: ZDOTDIR is honoured, `# >>>` blocks are
  # detected, and --fix with nothing new takes no backup.
  def test_config_scan_zdotdir_and_markers
    home, env = make_home('scan')
    zdot = "#{home}/zdot"
    FileUtils.mkdir_p(zdot)
    File.write("#{zdot}/.zshrc", "# >>> conda initialize >>>\n__conda_setup=x\n# <<< conda initialize <<<\n")
    File.write("#{home}/.zshrc", "alias home_only=1\n")
    zenv = env.merge('ZDOTDIR' => zdot)
    out, = wayu(zenv, 'config', 'scan')
    check('Test 15: config scan reads $ZDOTDIR/.zshrc and finds the # >>> block',
          out.include?('# >>> conda initialize >>>') && !out.include?('home_only'), out)
    wayu(zenv, 'config', 'scan', '--fix', '--yes')
    n1 = Dir.glob("#{home}/.local/share/wayu/backup/extra.zsh.backup.*").size
    wayu(zenv, 'config', 'scan', '--fix', '--yes')
    n2 = Dir.glob("#{home}/.local/share/wayu/backup/extra.zsh.backup.*").size
    check('Test 16: config scan --fix with nothing new takes no backup', n1 == n2, "#{n1} -> #{n2}")
  end
end

if __FILE__ == $0
  OptimizeIntegrationTest.new.run
end
