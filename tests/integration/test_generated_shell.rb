#!/usr/bin/env ruby
# Generated shell code under hostile conditions: user zsh options
# (NO_BARE_GLOB_QUAL / KSH_ARRAYS / NO_GLOB), aliases defined before wayu is
# sourced, [aliases] named like wayu's wrappers (OKAMI-224); nvm default /
# .nvmrc resolution (OKAMI-222); completion loading and compinit cache
# invalidation (OKAMI-234).

require 'open3'
require 'fileutils'
require_relative 'test_helper'

class GeneratedShellTest
  include WayuTestHelper

  NODE_VERSIONS = %w[v18.2.0 v20.1.0 v20.9.0 v20.18.0 v22.3.0].freeze

  TOML = <<~'TOML'
    [aliases]
    npm = "pnpm"
    conda = "echo aliased-conda"
    sdk = "echo aliased-sdk"
    ll = "ls -la"

    [tools]
    nvm = { kind = "nvm" }
    conda = { kind = "conda" }
    sdk = { kind = "lazy", init_script = "~/.sdk/init.sh", hook_commands = ["sdk"] }
  TOML

  HOSTILE_ALIASES = "alias ls=false grep=false rm=false sort=false tail=false mkdir=false " \
                    "mv=false npm=false node=false nvm=false conda=false mamba=false sdk=false"

  def initialize
    setup_test_env
  end

  def run
    puts "🚀 Testing generated shell code robustness..."
    puts

    begin
      build_project
      test_zsh_hostile_environments
      test_bash_hostile_aliases
      test_nvm_default_resolution
      test_nvmrc_resolution
      test_compinit_picks_up_new_completions
      test_env_values_and_functions_all_shells
      test_fresh_init_has_no_error_output
      test_script_path_sync_after_path_add
    ensure
      teardown_test_env
    end

    print_summary("generated shell")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  # Fresh HOME for `shell` with the test wayu.toml, a fake nvm install,
  # anaconda dir, a user function, extra.<ext> and wayu's own completions.
  def setup_home(name, shell, nvm_default: '20')
    home = "#{@tmp_home}/#{name}"
    FileUtils.rm_rf(home)
    FileUtils.mkdir_p(["#{home}/.config", "#{home}/anaconda3/bin", "#{home}/.nvm/alias/lts"])
    NODE_VERSIONS.each do |v|
      bin = "#{home}/.nvm/versions/node/#{v}/bin"
      FileUtils.mkdir_p(bin)
      File.write("#{bin}/node", "#!/bin/sh\necho #{v}\n")
      File.chmod(0o755, "#{bin}/node")
    end
    File.write("#{home}/.nvm/alias/lts/iron", "v20.18.0\n")
    File.write("#{home}/.nvm/alias/lts/*", "lts/iron\n")
    File.write("#{home}/.nvm/alias/default", "#{nvm_default}\n")
    env = { 'HOME' => home, 'SHELL' => "/bin/#{shell}", 'PATH' => '/usr/bin:/bin:/usr/sbin:/sbin', 'ZDOTDIR' => nil,
            'NVM_DIR' => nil, 'WAYU_CONFIG' => nil, 'XDG_CONFIG_HOME' => nil, 'XDG_DATA_HOME' => nil }
    Open3.capture3(env, @wayu_bin, 'init', '--shell', shell)
    cfg = "#{home}/.config/wayu"
    File.write("#{cfg}/wayu.toml", TOML)
    FileUtils.mkdir_p("#{cfg}/functions")
    File.write("#{cfg}/functions/myfn.#{shell}", "myfn() { echo myfn-ok; }\n")
    File.write("#{cfg}/extra.#{shell}", "EXTRA_LOADED=1\n")
    Open3.capture3(env, @wayu_bin, 'completions', 'generate')
    Open3.capture3(env, @wayu_bin, 'build', 'eval')
    [home, cfg, env]
  end

  def check(label, ok, detail)
    if ok
      puts "✓"; @passed += 1
    else
      puts "✗"; puts "  #{label}: #{detail}"; @failed += 1
    end
  end

  ZSH_PROBE = <<~'SH'
    print -r -- "node=$(node 2>&1) myfn=$(myfn 2>&1) extra=${EXTRA_LOADED-} nvm=${+functions[nvm]} sdk=${+functions[sdk]} conda=${+functions[conda]} comp=${_comps[wayu]-none}"
  SH

  # Every option/alias combination must source init.zsh without a single
  # error line and leave functions/, extra, lazy wrappers and completions set up.
  def test_zsh_hostile_environments
    _, cfg, env = setup_home('zsh_hostile', 'zsh')
    bad = Dir.glob("#{cfg}/*.zsh").reject { |f| system('zsh', '-n', f, out: File::NULL, err: File::NULL) }
    pres = {
      'NO_BARE_GLOB_QUAL' => 'unsetopt BARE_GLOB_QUAL',
      'KSH_ARRAYS' => 'setopt KSH_ARRAYS',
      'NO_GLOB' => 'setopt NO_GLOB',
      'hostile aliases' => HOSTILE_ALIASES,
      'all combined' => "unsetopt BARE_GLOB_QUAL; setopt KSH_ARRAYS NO_GLOB; #{HOSTILE_ALIASES}",
    }
    pres.each do |name, pre|
      print "Test: zsh init sources cleanly under #{name}... "
      script = "#{pre}\nsource '#{cfg}/init.zsh'\n#{ZSH_PROBE}"
      out, err, st = Open3.capture3(env, 'zsh', '-f', '-c', script)
      want_node = pre.include?('node=false') ? '' : 'v20.18.0'
      want = "node=#{want_node} myfn=myfn-ok extra=1 nvm=1 sdk=1 conda=1 comp=_wayu"
      check(name, bad.empty? && st.success? && err.strip.empty? && out.strip == want,
            "syntax=#{bad.map { |f| File.basename(f) }} out=#{out.strip.inspect} err=#{err.strip[0, 400]}")
    end
  end

  # bash: aliases (expand_aliases, as in an interactive shell) defined before
  # sourcing and [aliases] named like wrappers must not break lazy.bash;
  # wayu's own bash completion (completions/wayu.bash) is loaded.
  def test_bash_hostile_aliases
    _, cfg, env = setup_home('bash_hostile', 'bash')
    bad = Dir.glob("#{cfg}/*.bash").reject { |f| system('bash', '-n', f, out: File::NULL, err: File::NULL) }
    [['plain', ''], ['hostile aliases', HOSTILE_ALIASES]].each do |name, pre|
      print "Test: bash init sources cleanly with #{name}, loads wayu completion... "
      script = <<~SH
        shopt -s expand_aliases
        #{pre}
        source '#{cfg}/init.bash'
        echo "node=$(command node 2>&1) myfn=$(myfn 2>&1) extra=${EXTRA_LOADED-} nvm=$(declare -F nvm) sdk=$(declare -F sdk) conda=$(declare -F conda) comp=$(complete -p wayu 2>&1)"
      SH
      out, err, st = Open3.capture3(env, 'bash', '-c', script)
      want = 'node=v20.18.0 myfn=myfn-ok extra=1 nvm=nvm sdk=sdk conda=conda comp=complete -F _wayu_completion wayu'
      check(name, bad.empty? && st.success? && err.strip.empty? && out.strip == want,
            "syntax=#{bad.map { |f| File.basename(f) }} out=#{out.strip.inspect} err=#{err.strip[0, 400]}")
    end
  end

  # alias/default as nvm itself resolves it: highest matching install,
  # optional leading v, alias chains (lts/iron, lts/*), node = newest,
  # partial versions match whole components only.
  def test_nvm_default_resolution
    cases = { '20' => 'v20.18.0', 'v20' => 'v20.18.0', '20.1' => 'v20.1.0', 'v20.18.0' => 'v20.18.0',
              'lts/iron' => 'v20.18.0', 'lts/*' => 'v20.18.0', 'node' => 'v22.3.0', 'stable' => 'v22.3.0',
              '19' => '', '2' => '' }
    %w[zsh bash].each do |sh|
      print "Test: nvm default resolution (#{sh})... "
      fails = []
      cases.each do |spec, want|
        _, cfg, env = setup_home("nvm_#{sh}", sh, nvm_default: spec)
        probe = sh == 'zsh' ? "source '#{cfg}/init.zsh'; command node 2>/dev/null" :
                              "source '#{cfg}/init.bash'; command node 2>/dev/null"
        out, = Open3.capture3(env, sh, *(sh == 'zsh' ? ['-f'] : []), '-c', probe)
        fails << "#{spec}=>#{out.strip.inspect} (want #{want.inspect})" unless out.strip == want
      end
      check("nvm #{sh}", fails.empty?, fails.join(', '))
    end
  end

  # zsh .nvmrc fast path (startup and chpwd) uses the same resolution.
  def test_nvmrc_resolution
    print "Test: .nvmrc resolution (zsh)... "
    home, cfg, env = setup_home('nvmrc', 'zsh')
    { 'p20' => "20\n", 'p201' => "v20.1\n", 'plts' => "lts/*\n", 'p18' => " 18 \n" }.each do |d, c|
      FileUtils.mkdir_p("#{home}/#{d}")
      File.write("#{home}/#{d}/.nvmrc", c)
    end
    script = <<~SH
      source '#{cfg}/init.zsh'
      for d in p20 p201 plts p18; do cd "$HOME/$d"; print -n "$(command node) "; done
    SH
    out, err, = Open3.capture3(env, 'zsh', '-f', '-c', script)
    check('nvmrc', out.strip == 'v20.18.0 v20.1.0 v20.18.0 v18.2.0' && err.strip.empty?,
          "out=#{out.strip.inspect} err=#{err.strip[0, 300]}")
  end

  # `compinit -C` used to keep a stale .zcompdump forever: a completion added
  # with `wayu completions add` must be active in the next shell.
  def test_compinit_picks_up_new_completions
    print "Test: completions added by wayu reach the next zsh (dump refreshed)... "
    home, cfg, env = setup_home('compdump', 'zsh')
    probe = "source '#{cfg}/init.zsh'; print -r -- \"${_comps[foocmd]-none}\""
    first, = Open3.capture3(env, 'zsh', '-f', '-c', probe)
    dump_ok = File.exist?("#{home}/.zcompdump")
    src = "#{home}/_foocmd"
    File.write(src, "#compdef foocmd\n_foocmd() { _files }\n")
    Open3.capture3(env, @wayu_bin, 'completions', 'add', 'foocmd', src)
    # Same second as the dump (OKAMI-283): zsh's `-nt` compares whole
    # seconds, so pin both mtimes to one second; the listing must still win.
    t = File.mtime("#{home}/.zcompdump")
    File.utime(t, t, "#{cfg}/completions")
    second, err, = Open3.capture3(env, 'zsh', '-f', '-c', probe)
    third, = Open3.capture3(env, 'zsh', '-f', '-c', probe)
    check('compdump', dump_ok && first.strip == 'none' && second.strip == '_foocmd' && third.strip == '_foocmd',
          "dump=#{dump_ok} first=#{first.strip} second=#{second.strip} third=#{third.strip} err=#{err.strip[0, 200]}")
  end

  # [env] values that used to break a whole generated file: an unclosed `${`
  # (zsh/bash syntax error), `${VAR}` / a bare `$` (fish parse error), zsh
  # `${(e)...}` (ran commands), `$X:h` (zsh modifier). Every shell must
  # source core cleanly, keep later entries and agree on the values.
  # functions/<name>.<ext> is loaded by its own shell only (fish loads them
  # too; zsh used to source .fish files and fail).
  ENV_TOML = <<~'TOML'
    [paths]
    gobin = "$FZ_GO/bin"

    [env]
    FZ_GO = "${HOME}/go"
    FZ_PW = 'pa${ss'
    FZ_EFLAG = '${(e):-$(echo PWNED)}'
    FZ_POS = 'a$1$'
    FZ_MOD = '$HOME:hello'
    FZ_PCT = 'a$%b'
    FZ_LAST = "ok"
  TOML

  def test_env_values_and_functions_all_shells
    fish = %w[/opt/homebrew/bin/fish /usr/local/bin/fish /usr/bin/fish].find { |f| File.executable?(f) }
    shells = %w[zsh bash] + (fish ? ['fish'] : [])
    home = "#{@tmp_home}/env_values"
    FileUtils.rm_rf(home)
    FileUtils.mkdir_p(["#{home}/.config", "#{home}/go/bin"])
    env = { 'HOME' => home, 'SHELL' => '/bin/zsh', 'PATH' => '/usr/bin:/bin:/usr/sbin:/sbin', 'ZDOTDIR' => nil,
            'WAYU_CONFIG' => nil, 'XDG_CONFIG_HOME' => nil, 'XDG_DATA_HOME' => nil }
    shells.each { |s| Open3.capture3(env, @wayu_bin, 'init', '--shell', s) }
    cfg = "#{home}/.config/wayu"
    File.write("#{cfg}/wayu.toml", ENV_TOML)
    FileUtils.mkdir_p("#{cfg}/functions")
    File.write("#{cfg}/functions/fzfn.zsh", "fzfn() { echo fn-zsh; }\n")
    File.write("#{cfg}/functions/fzfn.bash", "fzfn() { echo fn-bash; }\n")
    File.write("#{cfg}/functions/fzfn.fish", "function fzfn; echo fn-fish; end\n")
    Open3.capture3(env, @wayu_bin, 'build')
    want_env = "FZ_GO=#{home}/go FZ_PW=pa${ss FZ_EFLAG=${(e):-$(echo PWNED)} FZ_POS=a$1$ " \
               "FZ_MOD=#{home}:hello FZ_PCT=a$%b FZ_LAST=ok"
    vars = %w[FZ_GO FZ_PW FZ_EFLAG FZ_POS FZ_MOD FZ_PCT FZ_LAST]
    shells.each do |sh|
      print "Test: tricky [env] values + functions/ load cleanly in #{sh}... "
      exe = sh == 'fish' ? fish : sh
      syntax = Dir.glob("#{cfg}/*.#{sh}").reject { |f| Open3.capture3(exe, '-n', f)[2].success? }
      probe = if sh == 'fish'
                "source '#{cfg}/init.fish'; for v in #{vars.join(' ')}; printf '%s=%s ' $v \"$$v\"; end; " \
                "echo; fzfn; contains -- '#{home}/go/bin' $PATH; and echo path-ok"
              else
                "source '#{cfg}/init.#{sh}'; for v in #{vars.join(' ')}; do printf '%s=%s ' \"$v\" \"$(printenv \"$v\")\"; done; " \
                "echo; fzfn; case \":$PATH:\" in *':#{home}/go/bin:'*) echo path-ok ;; esac"
              end
      args = { 'zsh' => ['-f', '-c'], 'bash' => ['--norc', '-c'], 'fish' => ['--no-config', '-c'] }[sh]
      out, err, st = Open3.capture3(env, exe, *args, probe)
      lines = out.lines.map(&:strip)
      ok = syntax.empty? && st.success? && err.strip.empty? &&
           lines == [want_env, "fn-#{sh}", 'path-ok']
      check("env #{sh}", ok, "syntax=#{syntax.map { |f| File.basename(f) }} out=#{out.inspect} err=#{err.strip[0, 400]}")
    end
  end

  # Scripts never reach a prompt, so the hook never runs (OKAMI-177): the
  # documented way is to call _wayu_paths_sync after `wayu path add/rm`.
  def test_script_path_sync_after_path_add
    %w[zsh bash].each do |sh|
      print "Test: script picks up 'wayu path add' via _wayu_paths_sync (#{sh})... "
      home, cfg, env = setup_home("script_sync_#{sh}", sh)
      dir = "#{home}/scriptbin"
      FileUtils.mkdir_p(dir)
      script = <<~SH
        source '#{cfg}/init.#{sh}'
        case ":$PATH:" in *':#{dir}:'*) echo early ;; esac
        '#{@wayu_bin}' path add '#{dir}' >/dev/null 2>&1 || echo add-failed
        _wayu_paths_sync
        case ":$PATH:" in *':#{dir}:'*) echo synced ;; esac
        '#{@wayu_bin}' path rm '#{dir}' >/dev/null 2>&1 || echo rm-failed
        _wayu_paths_sync
        case ":$PATH:" in *':#{dir}:'*) echo still-there ;; esac
      SH
      out, err, = Open3.capture3(env, sh, *(sh == 'zsh' ? ['-f'] : ['--norc']), '-c', script)
      check("script sync #{sh}", out.strip == 'synced' && err.strip.empty?,
            "out=#{out.strip.inspect} err=#{err.strip[0, 300]}")
    end
  end

  # `wayu init` on a fresh HOME used to print "ERROR: File not found:
  # .../wayu.toml" (startup pre-read of the not-yet-created file).
  def test_fresh_init_has_no_error_output
    print "Test: wayu init on a fresh HOME writes nothing to stderr... "
    home = "#{@tmp_home}/fresh_init"
    FileUtils.rm_rf(home)
    FileUtils.mkdir_p(home)
    env = { 'HOME' => home, 'SHELL' => '/bin/zsh', 'ZDOTDIR' => nil, 'WAYU_CONFIG' => nil,
            'XDG_CONFIG_HOME' => nil, 'XDG_DATA_HOME' => nil }
    _, err, st = Open3.capture3(env, @wayu_bin, 'init', '--shell', 'zsh')
    check('fresh init', st.success? && err.strip.empty? && File.exist?("#{home}/.config/wayu/wayu.toml"),
          "exit=#{st.exitstatus} err=#{err.strip[0, 300]}")
  end
end

if __FILE__ == $0
  GeneratedShellTest.new.run
end
