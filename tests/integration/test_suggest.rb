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
    _su_probe() { print -r -- "${1:-P}|B=[$BUFFER]|S=[$POSTDISPLAY]|C=$CURSOR|H=[${(j:;:)region_highlight}]" >> $HOME/probe.log; }
    _su_probe_w() { _su_probe P; }
    _su_probe_f() { _su_probe F; }
    zle -N _su_probe_w
    bindkey -M emacs '^X^P' _su_probe_w
    bindkey -M viins '^X^P' _su_probe_w
    bindkey -M vicmd '^X^P' _su_probe_w
    autoload -Uz add-zle-hook-widget
    zle -N _su_probe_f
    add-zle-hook-widget zle-line-finish _su_probe_f
    precmd() { print -r -- "$SU_MARK" }
  ZSH

  def setup_home(name, settings: "autosuggest = true\n", prompt: nil, plugin_json: false)
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
    File.write("#{home}/.zshenv", "source \"${WAYU_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/wayu}/init.zsh\"\n")
    # emacs keymap unless wayu's vi mode is on (as with EDITOR unset).
    File.write("#{home}/.zshrc", (prompt.to_s.include?('vi_mode = true') ? '' : "bindkey -e\n") + PROBE_RC)
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
end

if __FILE__ == $0
  SuggestTest.new.run
end
