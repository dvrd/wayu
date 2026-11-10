#!/usr/bin/env ruby
# Generated zsh startup (OKAMI-372, OKAMI-375): the compinit guard (an
# installer's `autoload -Uz compinit && compinit` in .zshrc after wayu ran
# compinit only registers the dirs it added), the dump signature over every
# fpath dir, idempotent re-sourcing, non-interactive shells skipping the
# interactive-only parts, TRAPUSR1 chaining, the fork-free prompt and the
# opt-in [settings] defer_plugins / lazy_compinit.

require 'open3'
require 'fileutils'
require 'json'
require 'pty'
require 'io/console'
require_relative 'test_helper'

class StartupTest
  include WayuTestHelper

  def initialize
    setup_test_env
  end

  def run
    puts "🚀 Testing generated zsh startup..."
    puts

    begin
      build_project
      test_installer_compinit_is_guarded
      test_compinit_guard_off
      test_dump_kept_with_empty_completions
      test_dump_signature_covers_fpath_dirs
      test_resourcing_is_idempotent
      test_non_interactive_skips_interactive_parts
      test_disabled_plugin_not_loaded
      test_trapusr1_is_chained
      test_prompt_renders_without_forks
      test_prompt_at_a_real_prompt
      test_vi_replace_symbol
      test_defer_plugins
      test_lazy_compinit
      test_settings_are_known_keys
    ensure
      teardown_test_env
    end

    print_summary("startup")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def check(label, ok, detail)
    if ok
      puts "✓"; @passed += 1
    else
      puts "✗"; puts "  #{label}: #{detail}"; @failed += 1
    end
  end

  def env_for(home, extra = {})
    { 'HOME' => home, 'SHELL' => '/bin/zsh', 'PATH' => '/usr/bin:/bin:/usr/sbin:/sbin', 'ZDOTDIR' => home,
      'WAYU_CONFIG' => nil, 'WAYU_CONFIG_DIR' => nil, 'WAYU_DATA_DIR' => nil, 'XDG_CONFIG_HOME' => nil,
      'XDG_DATA_HOME' => nil, 'XDG_CACHE_HOME' => nil, 'PROMPT' => nil, 'PS1' => nil, 'RPROMPT' => nil,
      'EDITOR' => nil, 'VISUAL' => nil, 'TERM' => 'xterm-256color' }.merge(extra)
  end

  # A HOME whose .zshenv sources init.zsh (wayu's documented setup), with a
  # PATH entry, an alias, a constant, a function, wayu's own completion and a
  # fake zsh-syntax-highlighting (defines _zsh_highlight, counts loads).
  # `settings`/`prompt` are appended to wayu.toml. Returns [home, data, env].
  def setup_home(name, settings: '', prompt: false, zshrc: '')
    home = "#{@tmp_home}/#{name}"
    FileUtils.rm_rf(home)
    FileUtils.mkdir_p(["#{home}/.config", "#{home}/pbin"])
    env = env_for(home)
    Open3.capture3(env, @wayu_bin, 'init', '--shell', 'zsh')
    cfg = "#{home}/.config/wayu"
    data = "#{home}/.local/share/wayu"
    toml = File.read("#{cfg}/wayu.toml")
    toml += "\n[settings]\n#{settings}\n" unless settings.empty?
    toml += "\n[prompt]\nenabled = true\n#{prompt}\n" if prompt
    File.write("#{cfg}/wayu.toml", toml)
    write_entries(paths: { 'pbin' => "#{home}/pbin" }, aliases: { 'll' => 'ls -la' }, env: { 'SU_CONST' => 'c1' }, data: data)
    FileUtils.mkdir_p("#{data}/functions")
    File.write("#{data}/functions/sufn.zsh", "sufn() { echo sufn-ok; }\n")
    zsh_hl = "#{data}/plugins/zsh-syntax-highlighting"
    FileUtils.mkdir_p(zsh_hl)
    File.write("#{zsh_hl}/zsh-syntax-highlighting.zsh", "_zsh_highlight() { :; }\n(( SU_HL_LOADS++ ))\n")
    # Registered in plugins.json: only enabled plugins load (OKAMI-310).
    File.write("#{data}/plugins.json", JSON.generate(
      'version' => '1.0', 'last_updated' => '2026-01-01T00:00:00Z', 'plugins' => [hl_plugin(data)]))
    Open3.capture3(env, @wayu_bin, 'completions', 'generate')
    _, err, st = Open3.capture3(env, @wayu_bin, 'build')
    warn "build failed: #{err}" unless st.success?
    File.write("#{home}/.zshenv", "source \"${WAYU_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/wayu}/init.zsh\"\n")
    File.write("#{home}/.zshrc", zshrc)
    [home, data, env]
  end

  def hl_plugin(data)
    { 'name' => 'zsh-syntax-highlighting', 'url' => 'https://github.com/zsh-users/zsh-syntax-highlighting.git',
      'enabled' => true, 'shell' => 'ZSH', 'installed_path' => "#{data}/plugins/zsh-syntax-highlighting",
      'use' => ['zsh-syntax-highlighting.zsh'] }
  end

  # An fpath dir an installer adds: `_sufoo` (#compdef sufoo) and an
  # #autoload helper.
  def installer_dir(home)
    dir = "#{home}/instcomp"
    FileUtils.mkdir_p(dir)
    File.write("#{dir}/_sufoo", "#compdef sufoo\n_sufoo() { _files }\n")
    File.write("#{dir}/_suhelper", "#autoload\n_suhelper() { :; }\n")
    dir
  end

  INSTALLER_RC = "fpath=($HOME/instcomp $fpath)\nautoload -Uz compinit && compinit\n"
  # Real compinit audits fpath and, in a non-tty shell, aborts on any insecure
  # dir (CI runners' system fpath dirs): -u skips the audit, the rest is real.
  INSTALLER_RC_NOAUDIT = "fpath=($HOME/instcomp $fpath)\nautoload -Uz compinit && compinit -u\n"

  def zsh(env, *args, **kw)
    Open3.capture3(env, 'zsh', *args, **kw)
  end

  # OKAMI-372: an installer's `autoload -Uz compinit && compinit` (plain, so
  # real compinit would audit fpath and rewrite the dump) after wayu's
  # compinit registers the installer's completions without redoing the
  # setup: the dump is not rewritten, compinit stays wayu's guard.
  def test_installer_compinit_is_guarded
    print "Test: installer compinit in .zshrc is guarded (completions registered, dump untouched)... "
    home, _, env = setup_home('guard', zshrc: INSTALLER_RC)
    installer_dir(home)
    probe = 'print -r -- "foo=${_comps[sufoo]-none} helper=${+functions[_suhelper]} wayu=${_comps[wayu]-none} guard=${functions[compinit]//[[:space:]]/}"'
    zsh(env, '-i', '-c', 'exit') # first shell builds the dump
    dump = "#{home}/.zcompdump"
    before = File.exist?(dump) && File.mtime(dump)
    sleep 1.1
    out, err, = zsh(env, '-i', '-c', probe)
    after = File.exist?(dump) && File.mtime(dump)
    want = 'foo=_sufoo helper=1 wayu=_wayu guard=_wayu_compinit_scan'
    check('guard', out.strip == want && err.strip.empty? && before && before == after,
          "out=#{out.strip.inspect} want=#{want.inspect} dump_rewritten=#{before != after} err=#{err.strip[0, 300]}")
  end

  # `[settings] compinit_guard = false`: a later compinit is zsh's own again.
  def test_compinit_guard_off
    print "Test: compinit_guard = false leaves later compinit calls alone... "
    home, data, env = setup_home('guard_off', settings: 'compinit_guard = false', zshrc: INSTALLER_RC_NOAUDIT)
    installer_dir(home)
    # Debian/Ubuntu's /etc/zsh/zshrc runs its own audited compinit unless
    # skip_global_compinit is set; with the guard off nothing intercepts it.
    env = env.merge('skip_global_compinit' => '1')
    out, err, = zsh(env, '-i', '-c', 'print -r -- "foo=${_comps[sufoo]-none} fn=${functions[compinit][1,40]}"')
    core = File.read("#{data}/core.zsh")
    check('guard off', out.strip.start_with?('foo=_sufoo fn=') && !out.include?('_wayu_compinit_scan') &&
                       !core.include?('function _wayu_compinit_guard') && err.strip.empty?,
          "out=#{out.strip.inspect} err=#{err.strip[0, 300]}")
  end

  # Right after `wayu init` the completions dir is empty and the stored
  # signature starts with a space; `read` without IFS= stripped it, so every
  # shell rebuilt the dump (a full compinit, ~300 ms).
  def test_dump_kept_with_empty_completions
    print "Test: fresh init (no completions) reuses the dump on the next shell... "
    home = "#{@tmp_home}/empty_comps"
    FileUtils.rm_rf(home)
    FileUtils.mkdir_p("#{home}/.config")
    env = env_for(home)
    Open3.capture3(env, @wayu_bin, 'init', '--shell', 'zsh')
    File.write("#{home}/.zshenv", "source \"${WAYU_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/wayu}/init.zsh\"\n")
    zsh(env, '-i', '-c', 'exit')
    dump = "#{home}/.zcompdump"
    before = File.exist?(dump) && File.mtime(dump)
    sleep 1.1
    _, err, = zsh(env, '-i', '-c', 'exit')
    after = File.exist?(dump) && File.mtime(dump)
    check('empty comps', before && before == after && err.strip.empty?,
          "dump_rewritten=#{before != after} err=#{err.strip[0, 300]}")
  end

  # The dump signature covers every fpath dir and its mtime: a completion
  # added to a non-wayu dir (brew's site-functions) reaches the next shell.
  def test_dump_signature_covers_fpath_dirs
    print "Test: a completion added to any fpath dir rebuilds the dump... "
    home, = setup_home('sig')
    site = "#{home}/site"
    FileUtils.mkdir_p(site)
    env = env_for(home)
    File.write("#{home}/.zshenv", "fpath=(#{site} $fpath)\n" + File.read("#{home}/.zshenv"))
    probe = 'print -r -- "${_comps[subaz]-none}"'
    first, = zsh(env, '-i', '-c', probe)
    File.write("#{site}/_subaz", "#compdef subaz\n_subaz() { _files }\n")
    t = Time.now + 5
    File.utime(t, t, site) # whole-second mtimes: make the change visible
    second, err, = zsh(env, '-i', '-c', probe)
    third, = zsh(env, '-i', '-c', probe)
    check('signature', first.strip == 'none' && second.strip == '_subaz' && third.strip == '_subaz' && err.strip.empty?,
          "first=#{first.strip} second=#{second.strip} third=#{third.strip} err=#{err.strip[0, 300]}")
  end

  # Sourcing init again (e.g. from both .zshenv and .zshrc): PATH order and
  # fpath unchanged, plugins not sourced again, compinit not redone.
  def test_resourcing_is_idempotent
    print "Test: re-sourcing init keeps PATH/fpath and doesn't reload plugins or compinit... "
    home, data, env = setup_home('resource')
    plugin = "#{data}/plugins/su-plug"
    FileUtils.mkdir_p(plugin)
    File.write("#{plugin}/su-plug.plugin.zsh", "(( SU_PLUG_LOADS++ ))\nexport PATH=\"$HOME/plugbin:$PATH\"\n")
    FileUtils.mkdir_p("#{home}/plugbin")
    File.write("#{data}/plugins.json", JSON.generate(
      'version' => '1.0', 'lastUpdated' => '2026-01-01T00:00:00Z',
      'plugins' => [{ 'name' => 'su-plug', 'url' => 'https://example.invalid/su-plug.git', 'enabled' => true, 'shell' => 'zsh',
                      'installed_path' => plugin, 'priority' => 100,
                      'git' => { 'branch' => 'main', 'commit' => 'abc', 'lastChecked' => '2026-01-01T00:00:00Z' },
                      'lastUpdated' => '2026-01-01T00:00:00Z' }, hl_plugin(data)]))
    _, perr, pst = Open3.capture3(env, @wayu_bin, 'plugin', 'priority', 'su-plug', '50')
    script = <<~'SH'
      path=( /opt/su-later $path )
      a="$PATH|${(j.:.)fpath}|$_wayu_comp_fpath[1]"
      source "$HOME/.local/share/wayu/init.zsh"
      b="$PATH|${(j.:.)fpath}|$_wayu_comp_fpath[1]"
      print -r -- "same=$([[ $a == $b ]] && echo 1 || echo 0) plug=$SU_PLUG_LOADS hl=$SU_HL_LOADS"
      print -r -- "A=$a"; print -r -- "B=$b"
    SH
    zsh(env, '-i', '-c', 'exit')
    dump = "#{home}/.zcompdump"
    before = File.mtime(dump)
    out, err, = zsh(env, '-i', '-c', script)
    check('resource', pst.success? && out.lines.first.to_s.strip == 'same=1 plug=1 hl=1' && err.strip.empty? &&
                      File.mtime(dump) == before,
          "priority=#{pst.exitstatus} #{perr.strip[0, 200]} out=#{out.inspect[0, 600]} err=#{err.strip[0, 300]}")
  end

  # OKAMI-375: `zsh -c` (scripts, IDEs) gets env, secrets loader, PATH,
  # functions and aliases, but no plugins, zsh-defer queue, TRAPUSR1, prompt
  # or compinit; an interactive shell gets them.
  def test_non_interactive_skips_interactive_parts
    print "Test: non-interactive zsh skips plugins/zsh-defer/TRAPUSR1/prompt, keeps env/PATH/aliases... "
    home, _, env = setup_home('nonint', prompt: "vi_mode = true\n")
    probe = 'print -r -- "c=$SU_CONST p=${path[(Ie)$HOME/pbin]} fn=$(sufn) al=${+aliases[ll]} hl=${+functions[_zsh_highlight]} ' \
            'usr1=${+functions[TRAPUSR1]} prompt=${+functions[_wayu_prompt_render]} comp=${+_comps} defer=$(zsh-defer true; echo $?)/${+_wayu_defer_queue}"'
    nonint, nerr, nst = zsh(env, '-c', probe)
    inter, ierr, = zsh(env, '-i', '-c', probe)
    want_n = 'c=c1 p=1 fn=sufn-ok al=1 hl=0 usr1=0 prompt=0 comp=0 defer=0/0'
    want_i = 'c=c1 p=1 fn=sufn-ok al=1 hl=1 usr1=1 prompt=1 comp=1 defer=0/1'
    check('nonint', nst.success? && nonint.strip == want_n && inter.strip == want_i && (nerr + ierr).strip.empty?,
          "nonint=#{nonint.strip.inspect} want=#{want_n.inspect} inter=#{inter.strip.inspect} want=#{want_i.inspect} err=#{(nerr + ierr).strip[0, 300]}")
  end

  # OKAMI-310: a disabled plugin is not loaded even though its checkout
  # exists (core had hard-coded zsh-autosuggestions / zsh-syntax-highlighting
  # fallbacks).
  def test_disabled_plugin_not_loaded
    print "Test: a disabled plugin is not loaded (no core fallback)... "
    _, data, env = setup_home('disabled')
    probe = 'print -r -- "hl=${+functions[_zsh_highlight]}"'
    before, = zsh(env, '-i', '-c', probe)
    _, derr, dst = Open3.capture3(env, @wayu_bin, 'plugin', 'disable', 'zsh-syntax-highlighting')
    after, err, = zsh(env, '-i', '-c', probe)
    core = File.read("#{data}/core.zsh")
    check('disabled', dst.success? && before.strip == 'hl=1' && after.strip == 'hl=0' && err.strip.empty? &&
                      !core.include?('zsh-syntax-highlighting.zsh') && !core.include?('zsh-autosuggestions.zsh'),
          "disable=#{dst.exitstatus} #{derr.strip[0, 200]} before=#{before.strip} after=#{after.strip} err=#{err.strip[0, 200]}")
  end

  # A TRAPUSR1 defined before wayu still runs (wayu's async prompt handler is
  # chained after it); re-sourcing doesn't chain wayu's handler to itself.
  def test_trapusr1_is_chained
    print "Test: a user TRAPUSR1 is kept and chained, not clobbered... "
    home, = setup_home('usr1', prompt: '')
    env = env_for(home)
    File.write("#{home}/.zshenv", "TRAPUSR1() { print -r -- user-usr1; }\n" + File.read("#{home}/.zshenv"))
    script = 'source "$HOME/.local/share/wayu/init.zsh"; kill -USR1 $$; sleep 0.2; ' \
             'print -r -- "prev=${+functions[_wayu_prev_TRAPUSR1]} self=${${functions[_wayu_prev_TRAPUSR1]}[(I)*_wayu_async_on_usr1*]}"'
    out, err, = zsh(env, '-i', '-c', script)
    check('usr1', out.lines.map(&:strip) == %w[user-usr1 prev=1\ self=0] && err.strip.empty?,
          "out=#{out.inspect} err=#{err.strip[0, 300]}")
  end

  PROMPT_TOML = <<~'T'
    vi_mode = true
    format = "{dir}{git_branch} {character}"

    [prompt.character]
    success_symbol = "[OK>](green)"
    error_symbol = "[ERR>](red)"
    vimcmd_symbol = "[NRM>](green)"
  T

  # OKAMI-375: PROMPT holds no command substitution; precmd renders it in
  # the shell (exit status, git branch, vi mode), and a branch name holding
  # `$(...)` stays text.
  def test_prompt_renders_without_forks
    print "Test: prompt is rendered in-shell (no $(...) in PROMPT), status/branch/vi mode correct... "
    home, _, env = setup_home('prompt', prompt: PROMPT_TOML)
    repo = "#{home}/repo"
    FileUtils.mkdir_p("#{repo}/.git")
    File.write("#{repo}/.git/HEAD", "ref: refs/heads/feat$(touch #{home}/PWNED)\n")
    # print -P with promptsubst expands PROMPT exactly as the prompt does.
    script = <<~'SH'
      source "$HOME/.local/share/wayu/init.zsh"
      cd ~/repo
      _wayu_update_git_info; _WAYU_VI_MODE=""  # exit-status symbol (no vi indicator)
      false
      _wayu_prompt_master
      p=${PROMPT#$'\n'}; print -r -- "1:$p"
      p=${PROMPT#$'\n'}; print -rP -- "2:$p"
      true
      _wayu_prompt_master
      _WAYU_VI_MODE=NORMAL
      _wayu_prompt_render
      p=${PROMPT#$'\n'}; print -rP -- "3:$p"
    SH
    out, err, = zsh(env, '-f', '-i', '-c', script)
    lines = out.split("\n").reject(&:empty?)
    ok = lines[0] == '1:${_WAYU_PS1}' && lines[1].to_s.include?('feat$(touch') && lines[1].to_s.include?('ERR>') &&
         lines[2].to_s.include?('NRM>') && !File.exist?("#{home}/PWNED") && err.strip.empty?
    check('prompt', ok, "out=#{out.inspect[0, 500]} err=#{err.strip[0, 300]}")
  end

  # The same at a real prompt: an interactive zsh reading commands from a
  # pipe draws its prompt (on stderr) after the precmd hooks.
  def test_prompt_at_a_real_prompt
    print "Test: real prompt shows the last exit status... "
    _, _, env = setup_home('prompt_real', prompt: PROMPT_TOML.sub("vi_mode = true\n", ''))
    _, err, = zsh(env, '-i', stdin_data: "false\ntrue\nexit\n")
    prompts = err.scan(/(OK>|ERR>)/).flatten
    check('real prompt', prompts.first(3) == %w[OK> ERR> OK>] && !err.include?('_wayu_prompt'),
          "prompts=#{prompts.inspect} err=#{err.inspect[0, 400]}")
  end

  # Run an interactive zsh in a pty, type `lines` once the first prompt is
  # up (marker printed by precmd), return everything it printed.
  def pty_session(env, lines, marker: 'SU_READY')
    out = +''
    PTY.spawn(env.reject { |_, v| v.nil? }.merge('SU_MARK' => marker), 'zsh', '-i', unsetenv_others: false) do |r, w, pid|
      r.winsize = [24, 120] rescue nil
      read_until = lambda do |pat, t|
        deadline = Time.now + t
        while Time.now < deadline
          break if pat && out.include?(pat)
          if IO.select([r], nil, nil, 0.05)
            begin
              out << r.readpartial(65_536)
            rescue EOFError, Errno::EIO
              break
            end
          end
        end
      end
      read_until.call(marker, 5)
      read_until.call(nil, 0.5) # let zle go idle (deferred work runs then)
      lines.each do |l|
        w.write(l)
        read_until.call(nil, 0.6)
      end
      w.write("exit\r")
      read_until.call(nil, 0.5)
      Process.kill('KILL', pid) rescue nil
      Process.wait(pid) rescue nil
    end
    out
  end

  # OKAMI-347: vi replace mode (`R`, and `r` while it waits for the
  # character) shows vimcmd_replace_symbol, not the insert symbol.
  def test_vi_replace_symbol
    print "Test: vi replace mode (R / r) shows vimcmd_replace_symbol... "
    toml = PROMPT_TOML + "vimcmd_replace_symbol = \"[RPL>](red)\"\n"
    _, _, env = setup_home('vi_replace', prompt: toml, zshrc: "precmd() { print -r -- \"$SU_MARK\" }\n")
    big_r = pty_session(env, ["\e", "R"])
    small_r = pty_session(env, ["\e", "r"])
    plain = pty_session(env, ["\e", "i"])
    check('vi replace', big_r.include?('RPL>') && small_r.include?('RPL>') && !plain.include?('RPL>'),
          "R=#{big_r.include?('RPL>')} r=#{small_r.include?('RPL>')} i=#{plain.include?('RPL>')}")
  end

  # `[settings] defer_plugins = true`: plugins load after the first prompt
  # is drawn (not during startup), and are there once the line editor ran.
  def test_defer_plugins
    print "Test: defer_plugins loads plugins after the first prompt... "
    _, data, env = setup_home('defer', settings: 'defer_plugins = true',
                                       zshrc: "precmd() { print -r -- \"$SU_MARK\" }\n")
    at_start, err, = zsh(env, '-i', '-c', 'print -r -- "hl=${+functions[_zsh_highlight]} q=${#_wayu_defer_queue}"')
    core = File.read("#{data}/core.zsh")
    out = pty_session(env, ["print -r -- \"HL=${+functions[_zsh_highlight]}:$SU_HL_LOADS\"\r"])
    check('defer', at_start.strip == 'hl=0 q=1' && core.include?('zsh-defer _wayu_plugins_load') && out.include?('HL=1:1') &&
                   err.strip.empty?,
          "at_start=#{at_start.strip.inspect} pty=#{out.inspect[-400, 400]} err=#{err.strip[0, 300]}")
  end

  # `[settings] lazy_compinit = true`: no compinit at startup; compdef calls
  # are queued; the first Tab runs compinit and replays them.
  def test_lazy_compinit
    print "Test: lazy_compinit sets up completion on the first Tab... "
    home, _, env = setup_home('lazy', settings: 'lazy_compinit = true',
                                      zshrc: "compdef _files sulazy\n#{INSTALLER_RC}precmd() { print -r -- \"$SU_MARK\" }\n")
    installer_dir(home)
    at_start, err, = zsh(env, '-i', '-c', 'print -r -- "comps=${+_comps} q=${#_wayu_compdef_queue} w=${widgets[expand-or-complete]}"')
    out = pty_session(env, ["\t", "\x15print -r -- \"C=${_comps[sulazy]-none}/${_comps[sufoo]-none}/${_comps[wayu]-none}\"\r"])
    want = 'comps=0 q=1 w=user:_wayu_compinit_lazy'
    check('lazy', at_start.strip == want && out.include?('C=_files/_sufoo/_wayu') && err.strip.empty?,
          "at_start=#{at_start.strip.inspect} want=#{want.inspect} pty=#{out.inspect[-400, 400]} err=#{err.strip[0, 300]}")
  end

  def test_settings_are_known_keys
    print "Test: the new [settings] keys validate without warnings... "
    home, = setup_home('validate', settings: "compinit_guard = true\ndefer_plugins = false\nlazy_compinit = false")
    out, err, st = Open3.capture3(env_for(home), @wayu_bin, 'toml', 'validate')
    check('validate', st.success? && !(out + err).include?('unknown key'), "exit=#{st.exitstatus} out=#{(out + err).strip[0, 300]}")
  end
end

if __FILE__ == $0
  StartupTest.new.run
end
