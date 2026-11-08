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

  ALIASES = { 'npm' => 'pnpm', 'conda' => 'echo aliased-conda', 'sdk' => 'echo aliased-sdk', 'll' => 'ls -la' }.freeze

  TOML = <<~'TOML'
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
      test_init_and_turbo_define_the_same
      test_prompt_vi_mode_and_widgets
      test_prompt_git_branch_without_git
      test_login_reorder_restored_at_first_prompt
      test_prompt_survives_later_ps1_reset
    ensure
      teardown_test_env
    end

    print_summary("generated shell")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  # Fresh HOME for `shell` with the test wayu.toml + aliases, a fake nvm
  # install, anaconda dir, a user function, extra.<ext> and wayu's own
  # completions. Returns [home, data dir (generated files), env, config dir].
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
    data = "#{home}/.local/share/wayu"
    File.write("#{cfg}/wayu.toml", TOML)
    write_entries(aliases: ALIASES, data: data)
    FileUtils.mkdir_p("#{cfg}/functions")
    File.write("#{cfg}/functions/myfn.#{shell}", "myfn() { echo myfn-ok; }\n")
    File.write("#{cfg}/extra.#{shell}", "EXTRA_LOADED=1\n")
    Open3.capture3(env, @wayu_bin, 'completions', 'generate')
    Open3.capture3(env, @wayu_bin, 'build')
    [home, data, env, cfg]
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

  # error line and leave functions/, extra, lazy wrappers and completions set up
  # (interactive: compinit runs in interactive shells only, OKAMI-284).
  # error line and leave functions/, extra, lazy wrappers and completions set up.
  def test_zsh_hostile_environments
    _, data, env = setup_home('zsh_hostile', 'zsh')
    bad = Dir.glob("#{data}/*.zsh").reject { |f| system('zsh', '-n', f, out: File::NULL, err: File::NULL) }
    pres = {
      'NO_BARE_GLOB_QUAL' => 'unsetopt BARE_GLOB_QUAL',
      'KSH_ARRAYS' => 'setopt KSH_ARRAYS',
      'NO_GLOB' => 'setopt NO_GLOB',
      'hostile aliases' => HOSTILE_ALIASES,
      'all combined' => "unsetopt BARE_GLOB_QUAL; setopt KSH_ARRAYS NO_GLOB; #{HOSTILE_ALIASES}",
    }
    pres.each do |name, pre|
      print "Test: zsh init sources cleanly under #{name}... "
      script = "#{pre}\nsource '#{data}/init.zsh'\n#{ZSH_PROBE}"
      out, err, st = Open3.capture3(env, 'zsh', '-f', '-i', '-c', script)
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
    _, data, env = setup_home('bash_hostile', 'bash')
    bad = Dir.glob("#{data}/*.bash").reject { |f| system('bash', '-n', f, out: File::NULL, err: File::NULL) }
    [['plain', ''], ['hostile aliases', HOSTILE_ALIASES]].each do |name, pre|
      print "Test: bash init sources cleanly with #{name}, loads wayu completion... "
      script = <<~SH
        shopt -s expand_aliases
        #{pre}
        source '#{data}/init.bash'
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
        _, data, env = setup_home("nvm_#{sh}", sh, nvm_default: spec)
        probe = sh == 'zsh' ? "source '#{data}/init.zsh'; command node 2>/dev/null" :
                              "source '#{data}/init.bash'; command node 2>/dev/null"
        out, = Open3.capture3(env, sh, *(sh == 'zsh' ? ['-f'] : []), '-c', probe)
        fails << "#{spec}=>#{out.strip.inspect} (want #{want.inspect})" unless out.strip == want
      end
      check("nvm #{sh}", fails.empty?, fails.join(', '))
    end
  end

  # zsh .nvmrc fast path (startup and chpwd) uses the same resolution.
  def test_nvmrc_resolution
    print "Test: .nvmrc resolution (zsh)... "
    home, data, env = setup_home('nvmrc', 'zsh')
    { 'p20' => "20\n", 'p201' => "v20.1\n", 'plts' => "lts/*\n", 'p18' => " 18 \n" }.each do |d, c|
      FileUtils.mkdir_p("#{home}/#{d}")
      File.write("#{home}/#{d}/.nvmrc", c)
    end
    script = <<~SH
      source '#{data}/init.zsh'
      for d in p20 p201 plts p18; do cd "$HOME/$d"; print -n "$(command node) "; done
    SH
    out, err, = Open3.capture3(env, 'zsh', '-f', '-c', script)
    check('nvmrc', out.strip == 'v20.18.0 v20.1.0 v20.18.0 v18.2.0' && err.strip.empty?,
          "out=#{out.strip.inspect} err=#{err.strip[0, 300]}")
  end

  # Loaded from .zshenv, the native prompt is set before /etc/zshrc (macOS:
  # `PS1="%n@%m %1~ %# "`) and .zshrc run; it must be in place again at the
  # first prompt, and the one-shot hook must remove itself.
  def test_prompt_survives_later_ps1_reset
    print "Test: native prompt survives a PS1 reset after .zshenv... "
    home = "#{@tmp_home}/prompt_reset"
    FileUtils.rm_rf(home)
    FileUtils.mkdir_p("#{home}/.config")
    env = { 'HOME' => home, 'SHELL' => '/bin/zsh', 'PATH' => '/usr/bin:/bin:/usr/sbin:/sbin', 'ZDOTDIR' => home,
            'WAYU_CONFIG' => nil, 'WAYU_DATA_DIR' => nil, 'WAYU_CONFIG_DIR' => nil, 'XDG_CONFIG_HOME' => nil }
    Open3.capture3(env, @wayu_bin, 'init', '--shell', 'zsh', stdin_data: '')
    File.write("#{home}/.config/wayu/wayu.toml", "[prompt]\nenabled = true\n")
    Open3.capture3(env, @wayu_bin, 'build')
    File.write("#{home}/.zshenv", "source \"${WAYU_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/wayu}/init.zsh\"\n")
    File.write("#{home}/.zshrc", "PS1=\"%n@%m %1~ %# \"\n")
    probe = 'for f in $precmd_functions; do $f; done; print -r -- "$PROMPT"; print -r -- "${(j: :)precmd_functions}"'
    out, err, = Open3.capture3(env, 'zsh', '-i', '-c', probe)
    lines = out.lines.map(&:chomp)
    hooks = lines.last.to_s
    check('prompt_reset', out.include?('$(_wayu_prompt_master)') && !hooks.include?('_wayu_prompt_reassert'),
          "out=#{out.inspect[0, 300]} err=#{err.strip[0, 200]}")
  end

  # A login shell runs .zprofile (macOS: /etc/zprofile's path_helper) after
  # .zshenv and can move dirs that were already on PATH ahead of wayu's. The
  # first prompt must put wayu's dirs back in front of those, while a dir
  # prepended later (in .zshrc) keeps its place. Simulated with a .zprofile
  # so it runs on Linux too.
  def test_login_reorder_restored_at_first_prompt
    print "Test: wayu PATH order restored at first prompt after a login reorder... "
    home = "#{@tmp_home}/login_reorder"
    FileUtils.rm_rf(home)
    FileUtils.mkdir_p(%w[a/bin b/bin pre/bin .config].map { |d| "#{home}/#{d}" })
    env = { 'HOME' => home, 'SHELL' => '/bin/zsh', 'PATH' => '/usr/bin:/bin:/usr/sbin:/sbin', 'ZDOTDIR' => home,
            'WAYU_CONFIG' => nil, 'WAYU_DATA_DIR' => nil, 'WAYU_CONFIG_DIR' => nil, 'XDG_CONFIG_HOME' => nil }
    Open3.capture3(env, @wayu_bin, 'init', '--shell', 'zsh', stdin_data: '')
    write_entries(paths: { 'a' => "#{home}/a/bin", 'b' => "#{home}/b/bin" }, data: "#{home}/.local/share/wayu")
    Open3.capture3(env, @wayu_bin, 'build')
    File.write("#{home}/.zshenv", "source \"${WAYU_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/wayu}/init.zsh\"\n")
    File.write("#{home}/.zprofile", "path=( /usr/sbin /bin ${path:#(/usr/sbin|/bin)} )\n")
    File.write("#{home}/.zshrc", "path=( $HOME/pre/bin $path )\n")
    probe = 'print -r -- "${(j.:.)path[1,4]}"; for f in $precmd_functions; do $f; done; print -r -- "${(j.:.)path[1,5]}"'
    out, err, = Open3.capture3(env, 'zsh', '-l', '-i', '-c', probe)
    before, after = out.lines.map(&:strip).last(2)
    want = ["#{home}/pre/bin", "#{home}/a/bin", "#{home}/b/bin", '/usr/sbin', '/bin'].join(':')
    check('login_reorder', before.to_s.start_with?("#{home}/pre/bin:/usr/sbin:/bin") && after == want,
          "before=#{before} after=#{after} err=#{err.strip[0, 200]}")
  end

  # with `wayu completions add` must be active in the next (interactive) shell.
  # with `wayu completions add` must be active in the next shell.
  def test_compinit_picks_up_new_completions
    print "Test: completions added by wayu reach the next zsh (dump refreshed)... "
    home, data, env = setup_home('compdump', 'zsh')
    probe = "source '#{data}/init.zsh'; print -r -- \"${_comps[foocmd]-none}\""
    first, = Open3.capture3(env, 'zsh', '-f', '-i', '-c', probe)
    dump_ok = File.exist?("#{home}/.zcompdump")
    src = "#{home}/_foocmd"
    File.write(src, "#compdef foocmd\n_foocmd() { _files }\n")
    Open3.capture3(env, @wayu_bin, 'completions', 'add', 'foocmd', src)
    # Same second as the dump (OKAMI-283): zsh's `-nt` compares whole
    # seconds, so pin both mtimes to one second; the listing must still win.
    t = File.mtime("#{home}/.zcompdump")
    File.utime(t, t, "#{data}/completions")
    second, err, = Open3.capture3(env, 'zsh', '-f', '-i', '-c', probe)
    third, = Open3.capture3(env, 'zsh', '-f', '-i', '-c', probe)
    check('compdump', dump_ok && first.strip == 'none' && second.strip == '_foocmd' && third.strip == '_foocmd',
          "dump=#{dump_ok} first=#{first.strip} second=#{second.strip} third=#{third.strip} err=#{err.strip[0, 200]}")
  end

  # Constant values that used to break a whole generated file: an unclosed `${`
  # (zsh/bash syntax error), `${VAR}` / a bare `$` (fish parse error), zsh
  # `${(e)...}` (ran commands), `$X:h` (zsh modifier). Every shell must
  # source core cleanly, keep later entries and agree on the values.
  # functions/<name>.<ext> is loaded by its own shell only; a file without
  # that extension is not loaded.
  ENV_PATHS = { 'gobin' => '$FZ_GO/bin' }.freeze
  ENV_VALUES = {
    'FZ_GO' => '${HOME}/go', 'FZ_PW' => 'pa${ss', 'FZ_EFLAG' => '${(e):-$(echo PWNED)}', 'FZ_POS' => 'a$1$',
    'FZ_MOD' => '$HOME:hello', 'FZ_PCT' => 'a$%b', 'FZ_LAST' => 'ok'
  }.freeze

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
    data = "#{home}/.local/share/wayu"
    write_entries(paths: ENV_PATHS, env: ENV_VALUES, data: data)
    FileUtils.mkdir_p("#{cfg}/functions")
    File.write("#{cfg}/functions/fzfn.zsh", "fzfn() { echo fn-zsh; }\n")
    File.write("#{cfg}/functions/fzfn.bash", "fzfn() { echo fn-bash; }\n")
    File.write("#{cfg}/functions/fzfn.fish", "function fzfn; echo fn-fish; end\n")
    File.write("#{cfg}/functions/fzfn_noext", "fzfn() { echo fn-noext; }\n")
    Open3.capture3(env, @wayu_bin, 'build')
    want_env = "FZ_GO=#{home}/go FZ_PW=pa${ss FZ_EFLAG=${(e):-$(echo PWNED)} FZ_POS=a$1$ " \
               "FZ_MOD=#{home}:hello FZ_PCT=a$%b FZ_LAST=ok"
    vars = %w[FZ_GO FZ_PW FZ_EFLAG FZ_POS FZ_MOD FZ_PCT FZ_LAST]
    shells.each do |sh|
      print "Test: tricky [env] values + functions/ load cleanly in #{sh}... "
      exe = sh == 'fish' ? fish : sh
      syntax = Dir.glob("#{data}/*.#{sh}").reject { |f| Open3.capture3(exe, '-n', f)[2].success? }
      probe = if sh == 'fish'
                "source '#{data}/init.fish'; for v in #{vars.join(' ')}; printf '%s=%s ' $v \"$$v\"; end; " \
                "echo; fzfn; contains -- '#{home}/go/bin' $PATH; and echo path-ok"
              else
                "source '#{data}/init.#{sh}'; for v in #{vars.join(' ')}; do printf '%s=%s ' \"$v\" \"$(printenv \"$v\")\"; done; " \
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
      home, data, env = setup_home("script_sync_#{sh}", sh)
      dir = "#{home}/scriptbin"
      FileUtils.mkdir_p(dir)
      script = <<~SH
        source '#{data}/init.#{sh}'
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
      data = over['WAYU_DATA_DIR'] || "#{home}/.local/share/wayu"
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
      data = "#{home}/.local/share/wayu"
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
                                   "source '#{data}/init.#{sh}'; echo \"$TOOLV\"")
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
    data = "#{home}/.local/share/wayu"
    base = File.read("#{cfg}/wayu.toml")
    File.write("#{home}/bin/argtool", "#!/bin/sh\nprintf 'export ARGS=\"'; printf '<%s>' \"$@\"; printf '\"\\n'\n")
    File.chmod(0o755, "#{home}/bin/argtool")
    pwn = "#{home}/PWNED"

    print "Test: [tools] args with quotes reach the tool as argv words... "
    File.write("#{cfg}/wayu.toml", base + "\n[tools]\nargtool = { args = \"init 'a b' --x=$HOME\" }\n")
    _, berr, bst = Open3.capture3(env, @wayu_bin, 'build')
    out, err, = Open3.capture3(clean_env(home, 'PATH' => "#{home}/bin:/usr/bin:/bin"), 'zsh', '-f', '-c',
                               "source '#{data}/init.zsh'; echo \"$ARGS\"")
    check('args quoted', bst.success? && berr.strip.empty? && out.strip == "<init><a b><--x=#{home}>" && err.strip.empty?,
          "build=#{bst.exitstatus} berr=#{berr.strip} out=#{out.inspect} err=#{err.strip[0, 300]}")

    ["init; touch #{pwn}", "init\ntouch #{pwn}", "init $(touch #{pwn})", 'init *'].each do |args|
      print "Test: [tools] args #{args.inspect} refused... "
      File.write("#{cfg}/wayu.toml", base + "\n[tools]\nargtool = { args = #{args.inspect} }\n")
      bout, berr, bst = Open3.capture3(env, @wayu_bin, 'build')
      bout += berr
      Open3.capture3(env, @wayu_bin, 'const', 'add', 'ARGS_PROBE', '1') # silent regeneration
      lazy = File.read("#{data}/core.zsh")
      Open3.capture3(clean_env(home, 'PATH' => "#{home}/bin:/usr/bin:/bin"), 'zsh', '-f', '-c', "source '#{data}/init.zsh'")
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
    data = "#{home}/.local/share/wayu"
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
    script = "#{hostile}\nsource '#{data}/init.zsh'\n#{funcs}\ncd '#{home}/repo'\n_wayu_update_git_info\n" \
             "print -r -- \"$(_wayu_prompt_full)\"\nprint -r -- \"ver=$(_wayu_version_cmd golang)\""
    out, err, st = Open3.capture3(clean_env(home, 'PATH' => "#{home}/bin:/usr/bin:/bin"), 'zsh', '-f', '-i', '-c', script)
    lines = out.lines.map(&:strip)
    ok = st.success? && err.strip.empty? && lines[0].to_s.include?('hostile-br') && !out.include?('HIJACK') &&
         lines[1] == 'ver=1.23.4'
    check('prompt hostile', ok, "out=#{out.inspect} err=#{err.strip[0, 400]}")
  end

  # OKAMI-285: the native prompt leaves the keymap alone unless
  # `[prompt] vi_mode = true`; then zle-line-init / zle-keymap-select are
  # chained to widgets that already exist (not replaced), KEYTIMEOUT is not
  # exported, and re-sourcing doesn't chain wayu's widget to itself.
  def test_prompt_vi_mode_and_widgets
    [[false, 'emacs'], [true, 'viins']].each do |vi, keymap|
      print "Test: native prompt with vi_mode=#{vi}: keymap #{keymap}, widgets chained... "
      home = "#{@tmp_home}/prompt_vi_#{vi}"
      FileUtils.rm_rf(home)
      FileUtils.mkdir_p("#{home}/.config")
      # zsh picks the vi keymap itself when $EDITOR/$VISUAL mention vi.
      env = clean_env(home, 'EDITOR' => nil, 'VISUAL' => nil, 'KEYTIMEOUT' => nil)
      Open3.capture3(env, @wayu_bin, 'init', '--shell', 'zsh')
      cfg = "#{home}/.config/wayu"
      data = "#{home}/.local/share/wayu"
      File.write("#{cfg}/wayu.toml", File.read("#{cfg}/wayu.toml") +
                 "\n[prompt]\nenabled = true\n#{vi ? "vi_mode = true\n" : ''}")
      Open3.capture3(env, @wayu_bin, 'build')
      script = <<~SH
        my_line_init() { MY_INIT=1; }
        zle -N zle-line-init my_line_init
        source '#{data}/init.zsh'
        source '#{data}/init.zsh'
        print -r -- "map=$(bindkey -lL main) kt=${(t)KEYTIMEOUT}:$KEYTIMEOUT li=${widgets[zle-line-init]} prev=${widgets[_wayu_prev_zle-line-init]-none} prevprev=${widgets[_wayu_prev__wayu_prev_zle-line-init]-none}"
      SH
      out, err, st = Open3.capture3(env, 'zsh', '-f', '-i', '-c', script)
      want = if vi
               "map=bindkey -A viins main kt=integer:1 li=user:_wayu_zle_line_init prev=user:my_line_init prevprev=none"
             else
               "map=bindkey -A emacs main kt=integer:40 li=user:my_line_init prev=none prevprev=none"
             end
      check("vi_mode=#{vi}", st.success? && err.strip.empty? && out.strip == want,
            "out=#{out.strip.inspect} want=#{want.inspect} err=#{err.strip[0, 300]}")
    end
  end

  # OKAMI-285: the git segment reads the branch without running git (a
  # `git` that fails proves it): subdirectories, detached HEAD (short id),
  # `git worktree` checkouts (.git file) and leaving the repo.
  def test_prompt_git_branch_without_git
    print "Test: native prompt git branch is read without forking git... "
    home = "#{@tmp_home}/prompt_git"
    FileUtils.rm_rf(home)
    FileUtils.mkdir_p(["#{home}/.config", "#{home}/bin"])
    env = clean_env(home)
    Open3.capture3(env, @wayu_bin, 'init', '--shell', 'zsh')
    cfg = "#{home}/.config/wayu"
    data = "#{home}/.local/share/wayu"
    File.write("#{cfg}/wayu.toml", File.read("#{cfg}/wayu.toml") + "\n[prompt]\nenabled = true\n")
    Open3.capture3(env, @wayu_bin, 'build')
    git_env = clean_env(home, 'GIT_CONFIG_NOSYSTEM' => '1')
    g = ->(*a) { Open3.capture3(git_env, 'git', '-c', 'user.name=t', '-c', 'user.email=t@t', '-c', 'commit.gpgsign=false', *a) }
    g.call('init', '-q', '-b', 'main-br', "#{home}/repo")
    g.call('-C', "#{home}/repo", 'commit', '-q', '--allow-empty', '-m', 'one')
    FileUtils.mkdir_p("#{home}/repo/sub/deep")
    g.call('-C', "#{home}/repo", 'worktree', 'add', '-q', '-b', 'wt-br', "#{home}/wt")
    sha, = g.call('-C', "#{home}/repo", 'rev-parse', 'HEAD')
    File.write("#{home}/bin/git", "#!/bin/sh\necho GIT-RAN >&2\nexit 1\n")
    File.chmod(0o755, "#{home}/bin/git")
    script = <<~SH
      source '#{data}/init.zsh'
      for d in repo/sub/deep wt . ; do cd "$HOME/$d"; _wayu_update_git_info; print -rn -- "[$_WAYU_GIT_BRANCH|${_WAYU_GIT_DIR:t}]"; done
      print -r -- '#{sha.strip}' > "$HOME/repo/.git/HEAD"
      cd "$HOME/repo"; _wayu_update_git_info; print -r -- "[$_WAYU_GIT_BRANCH]"
    SH
    out, err, = Open3.capture3(clean_env(home, 'PATH' => "#{home}/bin:/usr/bin:/bin"), 'zsh', '-f', '-i', '-c', script)
    want = "[main-br|repo][wt-br|wt][|][#{sha.strip[0, 7]}]"
    check('git branch', out.strip == want && !err.include?('GIT-RAN'),
          "out=#{out.strip.inspect} want=#{want.inspect} err=#{err.strip[0, 300]}")
  end

  # OKAMI-284: turbo.<ext> is the same generated output as core.<ext>, so a
  # shell that sources turbo ends up exactly like one that sources init:
  # same PATH, aliases, [env], functions (user + [tools] lazy wrappers),
  # completions and prompt hooks. A mutation keeps turbo in step.
  def test_init_and_turbo_define_the_same
    %w[zsh bash].each do |sh|
      print "Test: #{sh} init.#{sh} and turbo.#{sh} define the same things... "
      home, data, env, cfg = setup_home("turbo_#{sh}", sh)
      FileUtils.mkdir_p("#{home}/pbin")
      write_entries(paths: { 'pbin' => '~/pbin' }, aliases: ALIASES, env: { 'PARITY' => '$HOME/x' }, data: data)
      File.write("#{cfg}/wayu.toml", File.read("#{cfg}/wayu.toml") + (sh == 'zsh' ? "\n[prompt]\nenabled = true\n" : ''))
      Open3.capture3(env, @wayu_bin, '--shell', sh, 'build')
      _, terr, tst = Open3.capture3(env, @wayu_bin, '--shell', sh, 'export', '--turbo')
      Open3.capture3(env, @wayu_bin, '--shell', sh, 'alias', 'add', 'parity_late', 'echo late')
      probe = if sh == 'zsh'
                'print -r -- "PATH=$PATH"; alias; print -l ${(ok)functions}; print -r -- "precmd=$precmd_functions chpwd=$chpwd_functions"; ' \
                  'print -r -- "comp=${_comps[wayu]-none} PARITY=$PARITY prompt=${PROMPT:+set}"'
              else
                'echo "PATH=$PATH"; alias; declare -F; complete -p wayu; echo "PARITY=$PARITY PC=$PROMPT_COMMAND"'
              end
      run = lambda do |file|
        args = sh == 'zsh' ? ['zsh', '-f', '-i', '-c'] : ['bash', '--norc', '-c']
        Open3.capture3(env, *args, "source '#{data}/#{file}' >/dev/null 2>&1; #{probe}")
      end
      run.call("init.#{sh}") # warm-up: first zsh rebuilds the completion dump
      init_out, init_err, = run.call("init.#{sh}")
      turbo_out, turbo_err, = run.call("turbo.#{sh}")
      same_file = File.read("#{data}/turbo.#{sh}") == File.read("#{data}/core.#{sh}")
      ok = tst.success? && same_file && init_out == turbo_out && init_out.include?("#{home}/pbin") &&
           init_out.include?('parity_late') && init_out.include?('myfn') && init_out.include?("PARITY=#{home}/x") &&
           init_err.strip.empty? && turbo_err.strip.empty?
      check("#{sh} turbo parity", ok,
            "turbo=#{tst.exitstatus} #{terr.strip[0, 200]} same_file=#{same_file} " \
            "diff=#{(init_out.lines - turbo_out.lines).first(3).inspect}/#{(turbo_out.lines - init_out.lines).first(3).inspect} " \
            "err=#{(init_err + turbo_err).strip[0, 300]}")
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
    check('fresh init', st.success? && err.strip.empty? && File.exist?("#{home}/.config/wayu/wayu.toml") &&
                        File.exist?("#{home}/.local/share/wayu/init.zsh"),
          "exit=#{st.exitstatus} err=#{err.strip[0, 300]}")
  end
end

if __FILE__ == $0
  GeneratedShellTest.new.run
end
