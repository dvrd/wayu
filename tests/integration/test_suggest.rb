#!/usr/bin/env ruby
# Built-in autosuggestions (OKAMI-376, `[settings] autosuggest = true`):
# generated core.zsh carries the module only when enabled and skips the
# zsh-autosuggestions plugin, doctor warns while that plugin is enabled, and
# the real line editor (interactive zsh in a pty) shows, accepts and
# partially accepts suggestions from history.
#
# The line editor's state is read by a probe widget bound to ^X^P that
# appends BUFFER / POSTDISPLAY / CURSOR / region_highlight to $HOME/probe.log,
# and by a zle-line-finish hook added after wayu's (so it sees the line as
# it is left on screen). zsh-syntax-highlighting is a fixture that behaves
# like 0.8 on zsh >= 5.9 (its own redraw hook, own entries tagged memo=,
# foreign entries kept); WAYU_TEST_ZSH_HL=<checkout> uses a real one instead.

require 'open3'
require 'fileutils'
require 'json'
require 'pty'
require 'io/console'
require_relative 'test_helper'

class SuggestTest
  include WayuTestHelper

  def initialize
    setup_test_env
    @shell_errors = []
  end

  def run
    puts "💡 Testing built-in autosuggestions..."
    puts

    begin
      build_project
      test_core_has_module_only_when_enabled
      test_plugin_skipped_and_doctor_warns
      test_settings_validate
      if zsh_supported?
        test_suggest_in_line_editor
        test_suggest_with_defer_and_lazy
        test_suggest_vi_mode
        test_suggest_wide_and_multiline
        test_suggest_continuation_and_paste
        test_suggest_undo_yank_search
        test_suggest_vi_accept
        test_suggest_widget_wrappers
        test_suggest_no_errors
      else
        puts "(zsh < 5.3 or missing: line editor tests skipped)"
      end
    ensure
      teardown_test_env
    end

    print_summary("suggest")
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

  def zsh_supported?
    out, st = Open3.capture2('zsh', '-fc', 'print -r -- $ZSH_VERSION') rescue [nil, nil]
    return false unless st&.success?
    maj, min = out.strip.split('.').map(&:to_i)
    maj > 5 || (maj == 5 && min >= 3)
  end

  def env_for(home)
    { 'HOME' => home, 'SHELL' => '/bin/zsh', 'PATH' => '/usr/bin:/bin:/usr/sbin:/sbin', 'ZDOTDIR' => home,
      'WAYU_CONFIG' => nil, 'WAYU_CONFIG_DIR' => nil, 'WAYU_DATA_DIR' => nil, 'XDG_CONFIG_HOME' => nil,
      'XDG_DATA_HOME' => nil, 'XDG_CACHE_HOME' => nil, 'PROMPT' => nil, 'PS1' => nil, 'RPROMPT' => nil,
      'EDITOR' => nil, 'VISUAL' => nil, 'TERM' => 'xterm-256color', 'HISTFILE' => nil, 'GIT_CONFIG_GLOBAL' => nil }
  end

  HISTORY = [
    'print 日本語 🎉 done',
    "for i in 1 2\\\ndo print $i\\\ndone",
    'print -r -- ALPHA-old',
    'print -r -- ALPHA-one-two three',
    'ls *[ab]-glob-x',
    'print -r -- BETA-zzz',
    'echo pre',
    'echo pre-longer',
  ].freeze

  # Fake zsh-syntax-highlighting 0.8 (zsh >= 5.9 code path): one redraw
  # hook that replaces its own memo-tagged entry and keeps the others.
  FAKE_HL = <<~'ZSH'
    autoload -Uz add-zle-hook-widget
    _zsh_highlight() {
      region_highlight=( "${(@)region_highlight:#*memo=zsh-syntax-highlighting*}" )
      (( $#BUFFER )) && region_highlight+=( "0 2 fg=green, memo=zsh-syntax-highlighting" )
      return 0
    }
    _fake_hl_redraw() { true && _zsh_highlight; }
    add-zle-hook-widget zle-line-pre-redraw _fake_hl_redraw
  ZSH

  # Probe widget (^X^P) + a finish hook after wayu's, both logging to probe.log.
  PROBE_RC = <<~'ZSH'
    HISTFILE=$HOME/.zsh_history HISTSIZE=100 SAVEHIST=100
    _su_probe() {
      local nl=$'\n' us=$'\x1f'
      print -r -- "${1:-P}|B=[${BUFFER//$nl/$us}]|S=[${POSTDISPLAY//$nl/$us}]|C=$CURSOR|H=[${(j:;:)region_highlight}]" >> $HOME/probe.log
    }
    _su_probe_w() { _su_probe P; }
    _su_probe_f() { _su_probe F; }
    zle -N _su_probe_w
    bindkey -M emacs '^X^P' _su_probe_w
    bindkey -M viins '^X^P' _su_probe_w
    bindkey -M vicmd '^X^P' _su_probe_w
    autoload -Uz add-zle-hook-widget
    zle -N _su_probe_f
    add-zle-hook-widget zle-line-finish _su_probe_f
    bindkey -M emacs '^Xr' redo
    bindkey -M emacs '^Xy' yank
    autoload -Uz up-line-or-beginning-search
    zle -N up-line-or-beginning-search
    bindkey -M emacs '^[[A' up-line-or-beginning-search
    precmd() { print -r -- "$SU_MARK" }
  ZSH

  def setup_home(name, settings: "autosuggest = true\n", prompt: nil, plugin_json: false, rc_extra: '', zshenv_pre: '')
    home = "#{@tmp_home}/#{name}"
    FileUtils.rm_rf(home)
    FileUtils.mkdir_p("#{home}/.config")
    env = env_for(home)
    Open3.capture3(env, @wayu_bin, 'init', '--shell', 'zsh')
    cfg = "#{home}/.config/wayu"
    data = "#{home}/.local/share/wayu"
    toml = File.read("#{cfg}/wayu.toml")
    toml += "\n[settings]\n#{settings}\n" unless settings.empty?
    toml += "\n[prompt]\nenabled = true\n#{prompt}\n" if prompt
    File.write("#{cfg}/wayu.toml", toml)
    hl = "#{data}/plugins/zsh-syntax-highlighting"
    FileUtils.mkdir_p(hl)
    if ENV['WAYU_TEST_ZSH_HL'] && File.exist?("#{ENV['WAYU_TEST_ZSH_HL']}/zsh-syntax-highlighting.zsh")
      FileUtils.rm_rf(hl)
      FileUtils.cp_r(ENV['WAYU_TEST_ZSH_HL'], hl)
    else
      File.write("#{hl}/zsh-syntax-highlighting.zsh", FAKE_HL)
    end
    as = "#{data}/plugins/zsh-autosuggestions"
    FileUtils.mkdir_p(as)
    File.write("#{as}/zsh-autosuggestions.zsh", "_zsh_autosuggest_start() { :; }\n(( SU_AS_LOADS++ ))\n")
    if plugin_json
      File.write("#{data}/plugins.json", JSON.generate(
        'version' => '1.0', 'last_updated' => '2026-01-01T00:00:00Z',
        'plugins' => [{ 'name' => 'zsh-autosuggestions', 'url' => 'https://github.com/zsh-users/zsh-autosuggestions.git',
                        'enabled' => true, 'shell' => 'ZSH', 'installed_path' => as }]))
      _, err, st = Open3.capture3(env, @wayu_bin, 'plugin', 'priority', 'zsh-autosuggestions', '50')
      warn "plugin priority failed: #{err}" unless st.success?
    end
    _, err, st = Open3.capture3(env, @wayu_bin, 'build')
    warn "build failed: #{err}" unless st.success?
    File.write("#{home}/.zshenv", zshenv_pre + "source \"${WAYU_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/wayu}/init.zsh\"\n")
    # emacs keymap unless wayu's vi mode is on (as with EDITOR unset).
    File.write("#{home}/.zshrc", (prompt.to_s.include?('vi_mode = true') ? '' : "bindkey -e\n") + PROBE_RC + rc_extra)
    File.write("#{home}/.zsh_history", HISTORY.join("\n") + "\n")
    [home, data, env]
  end

  def test_core_has_module_only_when_enabled
    print "Test: core.zsh has the suggest module only with autosuggest = true... "
    _, on_data, = setup_home('gen_on')
    _, off_data, = setup_home('gen_off', settings: '')
    on = File.read("#{on_data}/core.zsh")
    off = File.read("#{off_data}/core.zsh")
    ok = on.include?('_wayu_suggest_redraw') && on.include?('wayu-suggest-accept') &&
         on.include?('_WAYU_PLUGINS_LOADED="${_WAYU_PLUGINS_LOADED-}:zsh-autosuggestions"') &&
         !on.include?('zsh-autosuggestions/zsh-autosuggestions.zsh') &&
         !off.include?('_wayu_suggest') && off.include?('zsh-autosuggestions/zsh-autosuggestions.zsh') &&
         on.index('# === Autosuggestions') < on.index('# === Plugins ===')
    check('core', ok, "on has module=#{on.include?('_wayu_suggest_redraw')} off has module=#{off.include?('_wayu_suggest')}")
  end

  # The plugin registered in plugins.json is not sourced (core marks it
  # loaded before plugins.zsh runs), syntax-highlighting still is, and
  # doctor names the conflict.
  def test_plugin_skipped_and_doctor_warns
    print "Test: zsh-autosuggestions plugin skipped while autosuggest = true; doctor warns... "
    home, data, env = setup_home('plugin_both', plugin_json: true)
    plugins_zsh = File.exist?("#{data}/plugins.zsh") ? File.read("#{data}/plugins.zsh") : ''
    probe = 'print -r -- "as=${SU_AS_LOADS:-0} hl=${+functions[_zsh_highlight]}"'
    out, err, = Open3.capture3(env, 'zsh', '-i', '-c', probe)
    dout, derr, = Open3.capture3(env, @wayu_bin, 'doctor', '--json')
    rows = (JSON.parse(dout)['checks'] rescue nil) || []
    warn_row = rows.find { |r| r['name'] == 'autosuggest' }
    _, off_data, off_env = setup_home('plugin_only', settings: '', plugin_json: true)
    off_out, = Open3.capture3(off_env, 'zsh', '-i', '-c', probe)
    doff, = Open3.capture3(off_env, @wayu_bin, 'doctor', '--json')
    ok = plugins_zsh.include?('zsh-autosuggestions.zsh') && out.strip == 'as=0 hl=1' && err.strip.empty? &&
         warn_row && warn_row['status'] == 'warning' && warn_row['message'].include?('zsh-autosuggestions') &&
         off_out.strip == 'as=1 hl=1' && !doff.include?('"autosuggest"') && File.exist?("#{off_data}/core.zsh")
    check('plugin', ok, "out=#{out.strip.inspect} off=#{off_out.strip.inspect} err=#{err.strip[0, 200]} " \
                        "doctor_row=#{warn_row.inspect} plugins.zsh=#{plugins_zsh[0, 200].inspect} derr=#{derr[0, 200]}")
    _ = home
  end

  def test_settings_validate
    print "Test: autosuggest keys validate; wrong types are errors... "
    good, = setup_home('val_ok', settings: "autosuggest = true\nautosuggest_style = \"fg=244,underline\"\n")
    o1, e1, s1 = Open3.capture3(env_for(good), @wayu_bin, 'toml', 'validate')
    bad, = setup_home('val_bad', settings: "autosuggest = \"yes\"\n")
    o2, e2, s2 = Open3.capture3(env_for(bad), @wayu_bin, 'toml', 'validate')
    bad_style, = setup_home('val_bad_style', settings: "autosuggest_style = 3\n")
    o3, e3, s3 = Open3.capture3(env_for(bad_style), @wayu_bin, 'toml', 'validate')
    ok = s1.success? && !(o1 + e1).include?('unknown key') && !s2.success? && !s3.success? &&
         (o2 + e2).include?('settings.autosuggest must be true or false') && (o3 + e3).include?('settings.autosuggest_style')
    check('validate', ok, "ok: exit=#{s1.exitstatus} #{(o1 + e1).strip[0, 200]} | bad: exit=#{s2.exitstatus} #{(o2 + e2).strip[0, 300]} | " \
                          "style: exit=#{s3.exitstatus} #{(o3 + e3).strip[0, 300]}")
  end

  # Run an interactive zsh in a pty; send each step once the line editor
  # is idle; return [screen output, probe.log lines].
  def pty_session(home, env, steps, marker: 'SU_READY')
    out = +''
    log = "#{home}/probe.log"
    FileUtils.rm_f(log)
    PTY.spawn(env.merge('SU_MARK' => marker), 'zsh', '-i') do |r, w, pid|
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
      read_until.call(nil, 0.4)
      steps.each do |s|
        w.write(s)
        read_until.call(nil, 0.35)
      end
      w.write("\x15exit\r")
      read_until.call(nil, 0.4)
      Process.kill('KILL', pid) rescue nil
      Process.wait(pid) rescue nil
    end
    @shell_errors.concat(out.scan(/[^\r\n]*_wayu_[a-z_]+:\d+:[^\r\n]*/))
    [out, File.exist?(log) ? File.readlines(log, chomp: true) : []]
  end

  PROBE = "\x18\x10".freeze # ^X^P
  CLEAR = "\x15".freeze     # ^U kill-whole-line

  def field(line, key)
    line.to_s[/\|#{key}=\[(.*?)\](\||$)/, 1] || line.to_s[/\|#{key}=([^|]*)/, 1]
  end

  # One line-editor session covering suggest / accept / partial accept /
  # glob chars / Enter / no suggestion for history navigation.
  def test_suggest_in_line_editor
    print "Test: line editor: suggest, accept (→, ^Y), partial (M-f), glob prefix, Enter runs typed text... "
    home, _, env = setup_home('pty')
    steps = [
      'print -r -- AL', PROBE,                    # 0 suggestion shown + highlighted
      "\e[C", PROBE,                              # 1 → accepts it all
      CLEAR, 'print -r -- AL', "\ef", PROBE,      # 2 M-f takes one word
      CLEAR, 'ls *[', PROBE,                      # 3 glob chars are literal
      CLEAR, 'ls *', PROBE,                       # 4 ... also with a longer match
      CLEAR, 'print -r -- AL', "\x19", PROBE,     # 5 ^Y (autosuggestions_accept_keys)
      CLEAR, 'print -r -- AL', "\e[D", PROBE,     # 6 cursor not at end: no suggestion
      CLEAR, 'zzz-nothing', PROBE,                # 7 no match
      CLEAR, "\e[A", "\e[A", PROBE,              # 8 up x2 to "echo pre": no "-longer" suggestion
      CLEAR, 'print -r -- A', 'LPHA-o', PROBE,    # 9 typed on through the suggestion
      'l', PROBE,                                 # 10 diverged from it: ALPHA-old
      CLEAR, 'print -r -- BE', "\r",              # Enter: typed text only (F line)
      "print -r -- \"LAST=[${history[$((HISTCMD-1))]}]\"\r",
    ]
    out, log = pty_session(home, env, steps)
    p = log.select { |l| l.start_with?('P|') }
    f = log.select { |l| l.start_with?('F|') }
    want_s0 = 'PHA-one-two three'
    hl0 = field(p[0], 'H').to_s
    errs = []
    errs << "0: #{p[0]}" unless field(p[0], 'B') == 'print -r -- AL' && field(p[0], 'S') == want_s0 &&
                                hl0.include?("14 #{14 + want_s0.size} fg=8") && hl0.include?('memo=zsh-syntax-highlighting')
    errs << "1: #{p[1]}" unless field(p[1], 'B') == 'print -r -- ALPHA-one-two three' && field(p[1], 'S') == '' &&
                                field(p[1], 'C') == '31' && !field(p[1], 'H').to_s.include?('fg=8')
    # forward-word: to the start of the next word (WORDCHARS has '-').
    errs << "2: #{p[2]}" unless field(p[2], 'B') == 'print -r -- ALPHA-one-two ' && field(p[2], 'S') == 'three'
    errs << "3: #{p[3]}" unless field(p[3], 'B') == 'ls *[' && field(p[3], 'S') == 'ab]-glob-x'
    errs << "4: #{p[4]}" unless field(p[4], 'B') == 'ls *' && field(p[4], 'S') == '[ab]-glob-x'
    errs << "5: #{p[5]}" unless field(p[5], 'B') == 'print -r -- ALPHA-one-two three' && field(p[5], 'S') == ''
    errs << "6: #{p[6]}" unless field(p[6], 'B') == 'print -r -- AL' && field(p[6], 'S') == '' && field(p[6], 'C') == '13'
    errs << "7: #{p[7]}" unless field(p[7], 'B') == 'zzz-nothing' && field(p[7], 'S') == ''
    errs << "8: #{p[8]}" unless field(p[8], 'B') == 'echo pre' && field(p[8], 'S') == ''
    # Typing on reuses the looked-up entry while it still matches.
    errs << "9: #{p[9]}" unless field(p[9], 'S') == 'ne-two three'
    errs << "10: #{p[10]}" unless field(p[10], 'B') == 'print -r -- ALPHA-ol' && field(p[10], 'S') == 'd'
    beta = f.find { |l| field(l, 'B') == 'print -r -- BE' }
    errs << "enter: finish=#{beta.inspect}" unless beta && field(beta, 'S') == '' && !field(beta, 'H').to_s.include?('fg=8')
    errs << 'Enter ran the suggestion' unless out.include?('LAST=[print -r -- BE]')
    errs << "probe count #{p.size}" unless p.size == 11
    check('pty', errs.empty?, "#{errs.join(' / ')} log=#{log.inspect[0, 900]}")
  end

  # Set up eagerly, so defer_plugins / lazy_compinit don't change it.
  def test_suggest_with_defer_and_lazy
    print "Test: works with defer_plugins + lazy_compinit... "
    home, _, env = setup_home('pty_defer', settings: "autosuggest = true\ndefer_plugins = true\nlazy_compinit = true\n")
    _, log = pty_session(home, env, ['print -r -- BE', PROBE])
    p = log.find { |l| l.start_with?('P|') }
    check('defer', field(p, 'S') == 'TA-zzz' && field(p, 'H').to_s.include?('memo=zsh-syntax-highlighting'),
          "log=#{log.inspect[0, 400]}")
  end

  # wayu's vi mode (`bindkey -v` in the prompt section, before the module):
  # suggestions in insert mode; in normal mode `A` (vi-add-eol) accepts.
  def test_suggest_vi_mode
    print "Test: vi mode: suggestion kept in normal mode, A accepts, w takes a word... "
    home, _, env = setup_home('pty_vi', prompt: "vi_mode = true\n")
    steps = [
      'print -r -- AL', PROBE,             # 0 viins
      "\e", PROBE,                         # 1 vicmd: still suggested
      'A', PROBE,                          # 2 vi-add-eol accepts
      "\e", 'S', 'print -r -- AL', "\e", 'w', PROBE, # 3 vicmd w: one word
    ]
    _, log = pty_session(home, env, steps)
    p = log.select { |l| l.start_with?('P|') }
    errs = []
    errs << "0: #{p[0]}" unless field(p[0], 'S') == 'PHA-one-two three'
    errs << "1: #{p[1]}" unless field(p[1], 'S') == 'PHA-one-two three'
    errs << "2: #{p[2]}" unless field(p[2], 'B') == 'print -r -- ALPHA-one-two three' && field(p[2], 'S') == ''
    errs << "3: #{p[3]}" unless field(p[3], 'B').to_s.start_with?('print -r -- ALPHA') && field(p[3], 'S').to_s.end_with?('three')
    check('vi', errs.empty?, "#{errs.join(' / ')} log=#{log.inspect[0, 700]}")
  end

  # [start, end, attrs] of the suggestion's region_highlight entry.
  def sug_entry(line)
    field(line, 'H').to_s.split(';').map(&:strip).map { |e| e.match(/\A(\d+) (\d+) (fg=8)(,|\s|$)/) }
                    .compact.map { |m| [m[1].to_i, m[2].to_i] }.first
  end

  # Wide characters / emoji: POSTDISPLAY and its highlight count characters;
  # a multi-line history entry is suggested and accepted whole.
  def test_suggest_wide_and_multiline
    print "Test: wide chars / emoji and multi-line history entries: suggested, highlighted, accepted... "
    home, _, env = setup_home('pty_wide')
    steps = [CLEAR, 'print 日', PROBE, "\e[C", PROBE,
             CLEAR, 'print 日本語 🎉', PROBE, "\ef", PROBE,
             CLEAR, 'for i', PROBE, "\x05", PROBE]
    _, log = pty_session(home, env, steps)
    p = log.select { |l| l.start_with?('P|') }
    us = "\x1f"
    errs = []
    errs << "0: #{p[0]}" unless field(p[0], 'S') == '本語 🎉 done' && sug_entry(p[0]) == [7, 7 + '本語 🎉 done'.size]
    errs << "1: #{p[1]}" unless field(p[1], 'B') == 'print 日本語 🎉 done' && field(p[1], 'S') == '' && sug_entry(p[1]).nil?
    errs << "2: #{p[2]}" unless field(p[2], 'S') == ' done' && sug_entry(p[2]) == [11, 16]
    errs << "3: #{p[3]}" unless field(p[3], 'B') == 'print 日本語 🎉 ' && field(p[3], 'S') == 'done' # M-f: start of the next word
    errs << "4: #{p[4]}" unless field(p[4], 'S') == " in 1 2#{us}do print $i#{us}done" && sug_entry(p[4]) == [5, 5 + 24]
    errs << "5: #{p[5]}" unless field(p[5], 'B') == "for i in 1 2#{us}do print $i#{us}done" && field(p[5], 'S') == ''
    check('wide', errs.empty? && p.size == 6, "#{errs.join(' / ')} log=#{log.inspect[0, 600]}")
  end

  # At a continuation prompt (PS2) the suggestion comes from what is typed
  # on that line; a pasted long line (bracketed paste) gets none, quickly.
  def test_suggest_continuation_and_paste
    print "Test: continuation line suggestion; bracketed paste of a long line... "
    home, _, env = setup_home('pty_ps2')
    long = 'echo ' + (1..600).map { |i| "w#{i}" }.join(' ')
    steps = ["echo \\\r", 'print -r -- AL', PROBE, "\e[C", PROBE, "\x03",
             CLEAR, "\e[200~#{long}\e[201~", PROBE, ' x', PROBE,
             CLEAR, "\e[200~print -r -- B\e[201~", PROBE]
    _, log = pty_session(home, env, steps)
    p = log.select { |l| l.start_with?('P|') }
    errs = []
    errs << "ps2: #{p[0]}" unless field(p[0], 'B') == 'print -r -- AL' && field(p[0], 'S') == 'PHA-one-two three'
    errs << "ps2 accept: #{p[1]}" unless field(p[1], 'B') == 'print -r -- ALPHA-one-two three'
    errs << "paste: #{p[2].to_s[0, 80]}" unless field(p[2], 'B') == long && field(p[2], 'S') == ''
    errs << "paste+x: #{p[3].to_s[0, 80]}" unless field(p[3], 'B') == "#{long} x" && field(p[3], 'S') == ''
    errs << "paste short: #{p[4]}" unless field(p[4], 'B') == 'print -r -- B' && field(p[4], 'S') == 'ETA-zzz'
    check('ps2', errs.empty? && p.size == 5, errs.join(' / '))
  end

  # Undo of an accept brings the suggestion back; kill + yank; ^R and
  # up-line-or-beginning-search show none.
  def test_suggest_undo_yank_search
    print "Test: undo/redo of accept, kill/yank, ^R, up-line-or-beginning-search... "
    home, _, env = setup_home('pty_undo')
    steps = [CLEAR, 'print -r -- AL', "\e[C", PROBE, "\x1f", PROBE, "\x18r", PROBE, # accept, ^_ undo, redo
             CLEAR, 'print -r -- AL', "\x17", PROBE, "\x18y", PROBE,              # ^W, yank (^Y accepts)
             CLEAR, 'print -r -- A', "\e[A", PROBE,                                # up-line-or-beginning-search
             CLEAR, ":\r", "\x12BETA", "\x05", PROBE]                         # (: resets the history position)                                     # ^R BETA, ^E
    _, log = pty_session(home, env, steps)
    p = log.select { |l| l.start_with?('P|') }
    full = 'print -r -- ALPHA-one-two three'
    errs = []
    errs << "accept: #{p[0]}" unless field(p[0], 'B') == full && field(p[0], 'S') == ''
    errs << "undo: #{p[1]}" unless field(p[1], 'B') == 'print -r -- AL' && field(p[1], 'S') == 'PHA-one-two three'
    errs << "redo: #{p[2]}" unless field(p[2], 'B') == full && field(p[2], 'S') == ''
    errs << "kill: #{p[3]}" unless field(p[3], 'B') == 'print -r -- ' && field(p[3], 'S') == 'BETA-zzz'
    errs << "yank: #{p[4]}" unless field(p[4], 'B') == 'print -r -- AL' && field(p[4], 'S') == 'PHA-one-two three'
    errs << "up: #{p[5]}" unless field(p[5], 'B') == full && field(p[5], 'S') == ''
    errs << "^R: #{p[6]}" unless field(p[6], 'B') == 'print -r -- BETA-zzz' && field(p[6], 'S') == ''
    check('undo', errs.empty? && p.size == 7, errs.join(' / '))
  end

  # vi mode: $ and l accept in normal mode; insert mode → accepts.
  def test_suggest_vi_accept
    print "Test: vi mode: $ / l / → accept, e takes a word... "
    home, _, env = setup_home('pty_vi_acc', prompt: "vi_mode = true\n")
    steps = ['print -r -- AL', "\e", '$', PROBE,
             "\e", 'S', 'print -r -- AL', "\e", 'l', PROBE,
             "\e", 'S', 'print -r -- AL', "\e[C", PROBE,
             "\e", 'S', 'print -r -- AL', "\e", 'e', PROBE]
    _, log = pty_session(home, env, steps)
    p = log.select { |l| l.start_with?('P|') }
    full = 'print -r -- ALPHA-one-two three'
    errs = []
    errs << "$: #{p[0]}" unless field(p[0], 'B') == full && field(p[0], 'S') == ''
    errs << "l: #{p[1]}" unless field(p[1], 'B') == full && field(p[1], 'S') == ''
    errs << "right: #{p[2]}" unless field(p[2], 'B') == full && field(p[2], 'S') == ''
    errs << "e: #{p[3]}" unless field(p[3], 'B').to_s.start_with?('print -r -- ALPHA') && field(p[3], 'B') != full &&
                                (field(p[3], 'B') + field(p[3], 'S').to_s) == full
    check('vi-accept', errs.empty? && p.size == 4, errs.join(' / '))
  end

  # Plugins wrapping the same widgets, after wayu (re-wrapping before every
  # prompt, like fzf-tab / zsh-autosuggestions) and before it.
  FAKE_WRAP = <<~'ZSH'
    _fw_wrap() {
      local w
      for w in self-insert forward-char forward-word end-of-line backward-delete-char; do
        [[ ${widgets[$w]-} == user:_fw_* ]] && continue
        zle -A $w _fw_orig_$w
        functions[_fw_$w]="(( FW_CALLS++ )); zle _fw_orig_$w -- \"\$@\""
        zle -N $w _fw_$w
      done
    }
    _fw_wrap
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd _fw_wrap
  ZSH
  EARLY_WRAP = <<~'ZSH'
    if [[ -o interactive ]]; then
      zle -A forward-char _ew_orig_fc
      _ew_fc() { (( EW_CALLS++ )); zle _ew_orig_fc -- "$@" }
      zle -N forward-char _ew_fc
    fi
  ZSH

  def test_suggest_widget_wrappers
    print "Test: other plugins wrapping the accept widgets (before and after wayu): accept / partial still work... "
    home, _, env = setup_home('pty_wrap', rc_extra: FAKE_WRAP, zshenv_pre: EARLY_WRAP)
    steps = ['print -r -- AL', PROBE, "\e[C", PROBE, CLEAR, 'print -r -- AL', "\ef", PROBE, CLEAR,
             "print -r -- \"FW=$FW_CALLS:$EW_CALLS\"\r", 'print -r -- AL', PROBE, "\e[C", PROBE]
    out, log = pty_session(home, env, steps)
    p = log.select { |l| l.start_with?('P|') }
    full = 'print -r -- ALPHA-one-two three'
    counts = out[/FW=(\d+):(\d+)/] ? [$1, $2].map(&:to_i) : []
    errs = []
    errs << "0: #{p[0]}" unless field(p[0], 'S') == 'PHA-one-two three'
    errs << "accept: #{p[1]}" unless field(p[1], 'B') == full && field(p[1], 'S') == ''
    errs << "M-f: #{p[2]}" unless field(p[2], 'B') == 'print -r -- ALPHA-one-two ' && field(p[2], 'S') == 'three'
    errs << "2nd prompt: #{p[3]}" unless field(p[3], 'S') == 'PHA-one-two three'
    errs << "2nd accept: #{p[4]}" unless field(p[4], 'B') == full
    errs << "counts #{counts}" unless counts.size == 2 && counts.all?(&:positive?)
    check('wrap', errs.empty?, errs.join(' / '))
  end

  def test_suggest_no_errors
    print "Test: no shell errors from the suggest module in any session... "
    check('errors', @shell_errors.empty?, @shell_errors.uniq.first(5).inspect)
  end
end

if __FILE__ == $0
  SuggestTest.new.run
end
