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
      test_dir_overrides_produce_working_init
      test_evalcache_binary_identity
      test_tools_args_never_run_code
      test_prompt_survives_hostile_commands
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

  FISH_BIN = %w[/opt/homebrew/bin/fish /usr/local/bin/fish /usr/bin/fish].find { |f| File.executable?(f) }
  SHELL_ARGS = { 'zsh' => ['-f', '-c'], 'bash' => ['--norc', '-c'], 'fish' => ['--no-config', '-c'] }.freeze

  def clean_env(home, extra = {})
    { 'HOME' => home, 'SHELL' => '/bin/zsh', 'PATH' => '/usr/bin:/bin:/usr/sbin:/sbin', 'ZDOTDIR' => nil,
      'WAYU_CONFIG' => nil, 'WAYU_CONFIG_DIR' => nil, 'WAYU_DATA_DIR' => nil, 'XDG_CONFIG_HOME' => nil,
      'XDG_DATA_HOME' => nil, 'XDG_CACHE_HOME' => nil }.merge(extra)
  end

  # OKAMI-243: with WAYU_CONFIG_DIR and/or WAYU_DATA_DIR given to wayu but NOT
  # exported in the shell, sourcing the generated init (by its absolute path,
  # as the rc line does) loads the right files without errors, and `wayu` run
  # from that shell targets the same dirs (core exports non-default dirs).
  def test_dir_overrides_produce_working_init
    shells = %w[zsh bash] + (FISH_BIN ? ['fish'] : [])
    layouts = {
      'config' => ->(h) { { 'WAYU_CONFIG_DIR' => "#{h}/cfg dir" } },
      'data' => ->(h) { { 'WAYU_DATA_DIR' => "#{h}/data" } },
      'both' => ->(h) { { 'WAYU_CONFIG_DIR' => "#{h}/cfg", 'WAYU_DATA_DIR' => "#{h}/data" } },
    }
    layouts.each do |name, mk|
      home = "#{@tmp_home}/dirs_#{name}"
      FileUtils.rm_rf(home)
      FileUtils.mkdir_p(["#{home}/.config", "#{home}/mybin"])
      over = mk.call(home)
      wenv = clean_env(home, over)
      shells.each { |s| Open3.capture3(wenv, @wayu_bin, 'init', '--shell', s) }
      Open3.capture3(wenv, @wayu_bin, 'path', 'add', "#{home}/mybin")
      Open3.capture3(wenv, @wayu_bin, 'const', 'add', 'DIRS_PROBE', name)
      data = over['WAYU_DATA_DIR'] || over['WAYU_CONFIG_DIR']
      shells.each do |sh|
        print "Test: init.#{sh} works with #{over.keys.join('+')} not exported... "
        exe = sh == 'fish' ? FISH_BIN : sh
        init = "#{data}/init.#{sh}"
        probe = if sh == 'fish'
                  "source '#{init}'; echo \"$DIRS_PROBE\"; contains -- '#{home}/mybin' $PATH; and echo path-ok; " \
                  "echo \"cfg=$WAYU_CONFIG_DIR data=$WAYU_DATA_DIR\""
                else
                  "source '#{init}'; echo \"$DIRS_PROBE\"; case \":$PATH:\" in *':#{home}/mybin:'*) echo path-ok ;; esac; " \
                  "echo \"cfg=${WAYU_CONFIG_DIR-} data=${WAYU_DATA_DIR-}\""
                end
        out, err, st = Open3.capture3(clean_env(home), exe, *SHELL_ARGS[sh], probe)
        lines = out.lines.map(&:strip)
        cfg = over['WAYU_CONFIG_DIR'] || "#{home}/.config/wayu"
        ok = File.exist?(init) && st.success? && err.strip.empty? && lines[0] == name && lines[1] == 'path-ok' &&
             lines[2] == "cfg=#{cfg} data=#{data}"
        check("dirs #{name} #{sh}", ok, "exists=#{File.exist?(init)} out=#{out.inspect} err=#{err.strip[0, 400]}")
      end
      print "Test: default ~/.config/wayu untouched with #{over.keys.join('+')}... "
      stray = Dir.glob("#{home}/.config/wayu/{core,init,path_sync}.*")
      check("dirs #{name} stray", stray.empty?, "stray=#{stray}")
    end
  end

  # OKAMI-242: the evalcache is keyed on the binary's identity, not on its
  # mtime alone: a replacement with an identical (old) mtime, or a PATH
  # symlink moved to another target with the same mtime (Nix store), must
  # regenerate the cached init code. `wayu build clean` drops the cache.
  def test_evalcache_binary_identity
    %w[zsh bash].each do |sh|
      print "Test: evalcache regenerates when the #{sh} tool binary changes (same mtime)... "
      home = "#{@tmp_home}/evalcache_#{sh}"
      FileUtils.rm_rf(home)
      FileUtils.mkdir_p(["#{home}/.config", "#{home}/bin", "#{home}/s1", "#{home}/s2"])
      env = clean_env(home, 'SHELL' => "/bin/#{sh}")
      Open3.capture3(env, @wayu_bin, 'init', '--shell', sh)
      cfg = "#{home}/.config/wayu"
      File.write("#{cfg}/wayu.toml", File.read("#{cfg}/wayu.toml") + "\n[tools]\nfaketool = { args = \"init #{sh}\" }\n")
      Open3.capture3(env, @wayu_bin, 'build')
      tool = "#{home}/bin/faketool"
      stamp = Time.at(1_577_836_800)
      # Install like a package manager: write a new file, then rename it over
      # the old one, so the replacement never reuses the old inode (a plain
      # rm + write can on Linux, making the binaries indistinguishable).
      put = lambda do |path, v|
        tmp = "#{path}.new"
        File.write(tmp, "#!/bin/sh\necho 'export TOOLV=#{v}'\n")
        File.chmod(0o755, tmp)
        File.utime(stamp, stamp, tmp)
        File.rename(tmp, path)
      end
      run = lambda do
        out, err, = Open3.capture3(clean_env(home, 'PATH' => "#{home}/bin:/usr/bin:/bin"), sh, *SHELL_ARGS[sh],
                                   "source '#{cfg}/init.#{sh}'; echo \"$TOOLV\"")
        [out.strip, err.strip]
      end
      put.call(tool, '1')
      seen = [run.call]
      put.call(tool, '2') # new inode, same size and mtime
      seen << run.call
      put.call("#{home}/s1/faketool", 'A')
      put.call("#{home}/s2/faketool", 'B')
      FileUtils.rm_f(tool)
      File.symlink("#{home}/s1/faketool", tool)
      seen << run.call
      FileUtils.rm_f(tool)
      File.symlink("#{home}/s2/faketool", tool)
      seen << run.call
      seen << run.call # cache hit
      _, _, clean_st = Open3.capture3(env, @wayu_bin, 'build', 'clean')
      gone = !Dir.exist?("#{home}/.cache/wayu/evalcache")
      want = %w[1 2 A B B]
      check("evalcache #{sh}", seen.map(&:first) == want && seen.all? { |s| s[1].empty? } && clean_st.success? && gone,
            "seen=#{seen.inspect} clean=#{clean_st.exitstatus} gone=#{gone}")
    end
  end

  # OKAMI-275: [tools] args are split into argv words and re-quoted; values
  # that would run code at startup are refused (`wayu build` exits 78 naming
  # the tool; other regenerations skip the tool).
  def test_tools_args_never_run_code
    home = "#{@tmp_home}/tool_args"
    FileUtils.rm_rf(home)
    FileUtils.mkdir_p(["#{home}/.config", "#{home}/bin"])
    env = clean_env(home)
    Open3.capture3(env, @wayu_bin, 'init', '--shell', 'zsh')
    cfg = "#{home}/.config/wayu"
    base = File.read("#{cfg}/wayu.toml")
    File.write("#{home}/bin/argtool", "#!/bin/sh\nprintf 'export ARGS=\"'; printf '<%s>' \"$@\"; printf '\"\\n'\n")
    File.chmod(0o755, "#{home}/bin/argtool")
    pwn = "#{home}/PWNED"

    print "Test: [tools] args with quotes reach the tool as argv words... "
    File.write("#{cfg}/wayu.toml", base + "\n[tools]\nargtool = { args = \"init 'a b' --x=$HOME\" }\n")
    _, berr, bst = Open3.capture3(env, @wayu_bin, 'build')
    out, err, = Open3.capture3(clean_env(home, 'PATH' => "#{home}/bin:/usr/bin:/bin"), 'zsh', '-f', '-c',
                               "source '#{cfg}/init.zsh'; echo \"$ARGS\"")
    check('args quoted', bst.success? && berr.strip.empty? && out.strip == "<init><a b><--x=#{home}>" && err.strip.empty?,
          "build=#{bst.exitstatus} berr=#{berr.strip} out=#{out.inspect} err=#{err.strip[0, 300]}")

    ["init; touch #{pwn}", "init\ntouch #{pwn}", "init $(touch #{pwn})", 'init *'].each do |args|
      print "Test: [tools] args #{args.inspect} refused... "
      File.write("#{cfg}/wayu.toml", base + "\n[tools]\nargtool = { args = #{args.inspect} }\n")
      bout, berr, bst = Open3.capture3(env, @wayu_bin, 'build')
      bout += berr
      Open3.capture3(env, @wayu_bin, 'const', 'add', 'ARGS_PROBE', '1') # silent regeneration
      lazy = File.read("#{cfg}/lazy.zsh")
      Open3.capture3(clean_env(home, 'PATH' => "#{home}/bin:/usr/bin:/bin"), 'zsh', '-f', '-c', "source '#{cfg}/init.zsh'")
      ok = bst.exitstatus == 78 && bout.include?('argtool') && !lazy.include?('_wayu_evalcache argtool') && !File.exist?(pwn)
      check("args refused #{args.inspect}", ok,
            "exit=#{bst.exitstatus} out=#{bout.strip[0, 200]} lazy_call=#{lazy.include?('_wayu_evalcache argtool')} pwned=#{File.exist?(pwn)}")
      Open3.capture3(env, @wayu_bin, 'const', 'rm', 'ARGS_PROBE')
    end
  end

  # OKAMI-279: with `[prompt] enabled = true`, aliases and functions named
  # git/awk/sed/... (defined before or after wayu is sourced) must not change
  # or break the native prompt.
  def test_prompt_survives_hostile_commands
    print "Test: native prompt ignores user git/awk/sed aliases and functions... "
    home = "#{@tmp_home}/prompt_hostile"
    FileUtils.rm_rf(home)
    FileUtils.mkdir_p(["#{home}/.config", "#{home}/repo", "#{home}/bin"])
    env = clean_env(home)
    Open3.capture3(env, @wayu_bin, 'init', '--shell', 'zsh')
    cfg = "#{home}/.config/wayu"
    File.write("#{cfg}/wayu.toml", File.read("#{cfg}/wayu.toml") +
               "\n[prompt]\nenabled = true\nformat = \"{dir}{git_branch}\"\n")
    Open3.capture3(env, @wayu_bin, 'build')
    git_env = clean_env(home, 'GIT_CONFIG_NOSYSTEM' => '1')
    Open3.capture3(git_env, 'git', 'init', '-q', '-b', 'hostile-br', "#{home}/repo")
    Open3.capture3(git_env, 'git', '-C', "#{home}/repo", '-c', 'user.name=t', '-c', 'user.email=t@t', '-c', 'commit.gpgsign=false',
                   'commit', '-q', '--allow-empty', '-m', 'init')
    File.write("#{home}/bin/go", "#!/bin/sh\necho 'go version go1.23.4 darwin/arm64'\n")
    File.chmod(0o755, "#{home}/bin/go")
    hostile = 'alias git=false awk=false sed=false head=false wc=false tr=false mktemp=false rm=false mv=false'
    funcs = 'git() { echo HIJACK; }; awk() { echo HIJACK; }; sed() { echo HIJACK; }'
    script = "#{hostile}\nsource '#{cfg}/init.zsh'\n#{funcs}\ncd '#{home}/repo'\n_wayu_update_git_info\n" \
             "print -r -- \"$(_wayu_prompt_full)\"\nprint -r -- \"ver=$(_wayu_version_cmd golang)\""
    out, err, st = Open3.capture3(clean_env(home, 'PATH' => "#{home}/bin:/usr/bin:/bin"), 'zsh', '-f', '-c', script)
    lines = out.lines.map(&:strip)
    ok = st.success? && err.strip.empty? && lines[0].to_s.include?('hostile-br') && !out.include?('HIJACK') &&
         lines[1] == 'ver=1.23.4'
    check('prompt hostile', ok, "out=#{out.inspect} err=#{err.strip[0, 400]}")
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
