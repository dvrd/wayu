#!/usr/bin/env ruby
# Built-in syntax highlighting (OKAMI-377, `[settings] highlight = true`):
# generated core.zsh carries the module only when enabled and skips the
# zsh-syntax-highlighting / fast-syntax-highlighting plugins, doctor warns
# while one is enabled, the settings validate, and the real line editor
# (interactive zsh in a pty) highlights each kind of word.
#
# The line editor's state is read by a probe widget bound to ^X^P that
# appends BUFFER and the region_highlight entries to $HOME/probe.log; the
# test turns wayu's entries into "[text]=style" (style attributes sorted,
# memo dropped) and compares them with the expected list.

require 'open3'
require 'fileutils'
require 'json'
require 'pty'
require 'io/console'
require_relative 'test_helper'

class HighlightTest
  include WayuTestHelper

  def initialize
    setup_test_env
  end

  def run
    puts "🎨 Testing built-in syntax highlighting..."
    puts

    begin
      build_project
      test_core_has_module_only_when_enabled
      test_plugins_skipped_and_doctor_warns
      test_settings_validate
      if zsh_supported?
        test_highlight_table
        test_with_autosuggest
        test_region_and_user_entries
        test_with_defer_and_lazy
        test_vi_mode
        test_resource_core
      else
        puts "(zsh < 5.3 or missing: line editor tests skipped)"
      end
    ensure
      teardown_test_env
    end

    print_summary("highlight")
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

  # Options, assignments and separators have no style by default (as in
  # zsh-syntax-highlighting): give them one so the spans are visible.
  STYLES = 'highlight_styles = { single-hyphen-option = "fg=201", double-hyphen-option = "fg=202", ' \
           'assign = "fg=203", commandseparator = "fg=204" }'.freeze

  # Probe widget (^X^P) logging BUFFER + region_highlight to probe.log.
  PROBE_RC = <<~'ZSH'
    HISTFILE=$HOME/.zsh_history HISTSIZE=100 SAVEHIST=100
    setopt interactivecomments
    alias ll='ls -l'
    alias -g GG='| grep'
    myfn() { :; }
    cd $HOME/w
    _hl_probe() {
      local nl=$'\n' us=$'\x1f'
      local -a w
      zstyle -a zle-line-pre-redraw widgets w
      print -r -- "P|B=[${BUFFER//$nl/$us}]|K=$KEYMAP|W=${#${(@M)w:#*_wayu_hl_redraw}}|H=[${(j:;:)region_highlight}]" >> $HOME/probe.log
    }
    zle -N _hl_probe
    bindkey -M emacs '^X^P' _hl_probe
    bindkey -M viins '^X^P' _hl_probe
    bindkey -M vicmd '^X^P' _hl_probe
    precmd() { print -r -- "$HL_MARK" }
  ZSH

  def setup_home(name, settings: "highlight = true\n#{STYLES}\n", prompt: nil, plugin_json: false, rc_extra: '')
    home = "#{@tmp_home}/#{name}"
    FileUtils.rm_rf(home)
    FileUtils.mkdir_p("#{home}/.config")
    FileUtils.mkdir_p("#{home}/w/dir")
    File.write("#{home}/w/exists.txt", "x\n")
    env = env_for(home)
    Open3.capture3(env, @wayu_bin, 'init', '--shell', 'zsh')
    cfg = "#{home}/.config/wayu"
    data = "#{home}/.local/share/wayu"
    toml = File.read("#{cfg}/wayu.toml")
    toml += "\n[settings]\n#{settings}\n" unless settings.empty?
    toml += "\n[prompt]\nenabled = true\n#{prompt}\n" if prompt
    File.write("#{cfg}/wayu.toml", toml)
    plugins = []
    { 'zsh-syntax-highlighting' => 'zsh-syntax-highlighting.zsh',
      'fast-syntax-highlighting' => 'fast-syntax-highlighting.plugin.zsh' }.each do |pname, file|
      dir = "#{data}/plugins/#{pname}"
      FileUtils.mkdir_p(dir)
      var = pname.start_with?('fast') ? 'HL_FSH_LOADS' : 'HL_ZSH_LOADS'
      File.write("#{dir}/#{file}", "(( #{var}++ ))\n#{pname.start_with?('fast') ? '' : '_zsh_highlight() { :; }'}\n")
      plugins << { 'name' => pname, 'url' => "https://github.com/x/#{pname}.git", 'enabled' => true,
                   'shell' => 'ZSH', 'installed_path' => dir, 'use' => [file] }
    end
    if plugin_json
      File.write("#{data}/plugins.json", JSON.generate(
        'version' => '1.0', 'last_updated' => '2026-01-01T00:00:00Z', 'plugins' => plugins))
      # Any plugin command rewrites plugins.zsh from plugins.json.
      _, err, st = Open3.capture3(env, @wayu_bin, 'plugin', 'priority', 'fast-syntax-highlighting', '50')
      warn "plugin priority failed: #{err}" unless st.success?
    end
    _, err, st = Open3.capture3(env, @wayu_bin, 'build')
    warn "build failed: #{err}" unless st.success?
    File.write("#{home}/.zshenv", "source \"${WAYU_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/wayu}/init.zsh\"\n")
    File.write("#{home}/.zshrc", (prompt.to_s.include?('vi_mode = true') ? '' : "bindkey -e\n") + PROBE_RC + rc_extra)
    File.write("#{home}/.zsh_history", "print -r -- ALPHA-one-two\n")
    [home, data, env]
  end

  def test_core_has_module_only_when_enabled
    print "Test: core.zsh has the highlight module only with highlight = true; plugins skipped... "
    _, on_data, = setup_home('gen_on')
    _, off_data, = setup_home('gen_off', settings: '')
    on = File.read("#{on_data}/core.zsh")
    off = File.read("#{off_data}/core.zsh")
    ok = on.include?('_wayu_hl_redraw') && on.include?("single-hyphen-option 'fg=201'") &&
         on.include?("unknown-token 'fg=red,bold'") && on.include?("commandseparator 'fg=204'") &&
         on.include?('_WAYU_PLUGINS_LOADED="${_WAYU_PLUGINS_LOADED-}:zsh-syntax-highlighting"') &&
         on.include?('_WAYU_PLUGINS_LOADED="${_WAYU_PLUGINS_LOADED-}:fast-syntax-highlighting"') &&
         !on.include?('zsh-syntax-highlighting/zsh-syntax-highlighting.zsh') &&
         !off.include?('_wayu_hl') && off.include?('zsh-syntax-highlighting/zsh-syntax-highlighting.zsh') &&
         on.index('# === Syntax highlighting') < on.index('# === Plugins ===')
    _, st = Open3.capture2e('zsh', '-n', "#{on_data}/core.zsh")
    check('core', ok && st.success?, "on has module=#{on.include?('_wayu_hl_redraw')} off has module=#{off.include?('_wayu_hl')} zsh -n=#{st.exitstatus}")
  end

  # Both plugins registered in plugins.json are not sourced (core marks them
  # loaded before plugins.zsh runs) and doctor names the conflict; with the
  # setting off they load.
  def test_plugins_skipped_and_doctor_warns
    print "Test: highlighter plugins skipped while highlight = true; doctor warns... "
    _, data, env = setup_home('plugin_both', plugin_json: true)
    plugins_zsh = File.exist?("#{data}/plugins.zsh") ? File.read("#{data}/plugins.zsh") : ''
    probe = 'print -r -- "zsh=${HL_ZSH_LOADS:-0} fsh=${HL_FSH_LOADS:-0}"'
    out, err, = Open3.capture3(env, 'zsh', '-i', '-c', probe)
    dout, derr, = Open3.capture3(env, @wayu_bin, 'doctor', '--json')
    rows = (JSON.parse(dout)['checks'] rescue nil) || []
    row = rows.find { |r| r['name'] == 'highlight' }
    _, _, off_env = setup_home('plugin_only', settings: '', plugin_json: true)
    off_out, = Open3.capture3(off_env, 'zsh', '-i', '-c', probe)
    doff, = Open3.capture3(off_env, @wayu_bin, 'doctor', '--json')
    ok = plugins_zsh.include?('zsh-syntax-highlighting.zsh') && plugins_zsh.include?('fast-syntax-highlighting.plugin.zsh') &&
         out.strip == 'zsh=0 fsh=0' && row && row['status'] == 'warning' &&
         row['message'].include?('syntax-highlighting plugin is enabled') &&
         off_out.strip == 'zsh=1 fsh=1' && !doff.include?('"highlight"')
    check('plugins', ok, "out=#{out.strip.inspect} err=#{err.strip[0, 200]} off=#{off_out.strip.inspect} " \
                         "row=#{row.inspect} plugins.zsh=#{plugins_zsh[0, 300].inspect} derr=#{derr[0, 200]}")
  end

  def test_settings_validate
    print "Test: highlight keys validate; wrong types / unknown styles reported... "
    good, = setup_home('val_ok', settings: "highlight = true\n#{STYLES}\n")
    o1, e1, s1 = Open3.capture3(env_for(good), @wayu_bin, 'toml', 'validate')
    sub, = setup_home('val_sub', settings: "highlight = true\n[settings.highlight_styles]\ncommand = \"fg=blue\"\ncomment = \"none\"\n")
    o2, e2, s2 = Open3.capture3(env_for(sub), @wayu_bin, 'toml', 'validate')
    sub_core = File.read("#{sub}/.local/share/wayu/core.zsh")
    unknown, = setup_home('val_unknown', settings: "highlight = true\nhighlight_styles = { nosuch = \"fg=1\" }\n")
    o5, e5, s5 = Open3.capture3(env_for(unknown), @wayu_bin, 'toml', 'validate')
    results = { "highlight = \"yes\"\n" => 'settings.highlight must be true or false',
                "highlight_styles = { command = 3 }\n" => 'settings.highlight_styles.command must be',
                "[settings.highlight_styles]\ncomment = \"fg=1\\nbold\"\n" => 'settings.highlight_styles.comment must be',
                "highlight_styles = \"fg=1\"\n" => 'settings.highlight_styles must be a table' }.map do |settings, want|
      bad, = setup_home('val_bad', settings: settings)
      o, e, s = Open3.capture3(env_for(bad), @wayu_bin, 'toml', 'validate')
      [!s.success? && (o + e).include?(want), "#{settings.inspect}: exit=#{s.exitstatus} #{(o + e).strip[0, 200]}"]
    end
    ok = s1.success? && !(o1 + e1).include?('unknown key') &&
         s2.success? && !(o2 + e2).include?('unknown') && sub_core.include?("command 'fg=blue'") && sub_core.include?("comment ''") &&
         s5.success? && (o5 + e5).include?('unknown key settings.highlight_styles.nosuch') && results.all?(&:first)
    check('validate', ok, "ok=#{s1.exitstatus} #{(o1 + e1).strip[0, 200]} | sub=#{s2.exitstatus} #{(o2 + e2).strip[0, 200]} | " \
                          "unknown=#{s5.exitstatus} #{(o5 + e5).strip[0, 200]} | #{results.reject(&:first).map(&:last).join(' | ')}")
  end

  # Run an interactive zsh in a pty; send each step once the line editor
  # is idle; return [screen output, probe.log lines].
  def pty_session(home, env, steps, marker: 'HL_READY')
    out = +''
    log = "#{home}/probe.log"
    FileUtils.rm_f(log)
    PTY.spawn(env.merge('HL_MARK' => marker), 'zsh', '-i') do |r, w, pid|
      r.winsize = [24, 160] rescue nil
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
        read_until.call(nil, 0.3)
      end
      w.write("\x15exit\r")
      read_until.call(nil, 0.4)
      Process.kill('KILL', pid) rescue nil
      Process.wait(pid) rescue nil
    end
    [out, File.exist?(log) ? File.readlines(log, chomp: true) : []]
  end

  PROBE = "\x18\x10".freeze # ^X^P
  CLEAR = "\x15\x08\x15".freeze # ^U kill-whole-line; ^H ^U: the line above

  def field(line, key)
    line.to_s[/\|#{key}=\[(.*?)\](\||$)/, 1] || line.to_s[/\|#{key}=([^|]*)/, 1]
  end

  # region_highlight entries of a probe line: [[start, end, attrs, memo]].
  def entries(line)
    field(line, 'H').to_s.split(';').map do |e|
      m = e.strip.match(/\AP?(\d+) (\d+) (.*)\z/) or next
      attrs = m[3].split(/[\s,]+/).reject(&:empty?)
      memo = attrs.find { |a| a.start_with?('memo=') }
      [m[1].to_i, m[2].to_i, (attrs - [memo]).sort.join(','), memo]
    end.compact
  end

  # wayu's entries of a probe line as "[text]=style" (style attrs sorted).
  def spans(line)
    buf = field(line, 'B').to_s.tr("\x1f", "\n")
    entries(line).select { |e| e[3] == 'memo=wayu-highlight' }.map { |s, e, a, _| "[#{buf[s...e]}]=#{a}" }
  end

  G = 'fg=green'.freeze
  Y = 'fg=yellow'.freeze
  C = 'fg=cyan'.freeze
  M = 'fg=magenta'.freeze
  SEP = 'fg=204'.freeze
  OPT1 = 'fg=201'.freeze
  OPT2 = 'fg=202'.freeze
  ASSIGN = 'fg=203'.freeze
  ERR = 'bold,fg=red'.freeze
  PRE = 'fg=green,underline'.freeze
  UL = 'underline'.freeze

  # [typed keys, expected spans]. ^V^J inserts a newline.
  CASES = [
    ['ls', ["[ls]=#{G}"]],
    ['nosuchcmd x', ["[nosuchcmd]=#{ERR}"]],
    ['cd', ["[cd]=#{G}"]],
    ['ll', ["[ll]=#{G}"]],
    ['myfn', ["[myfn]=#{G}"]],
    ['if true; then ls; fi', ["[if]=#{Y}", "[true]=#{G}", "[;]=#{SEP}", "[then]=#{Y}", "[ls]=#{G}", "[;]=#{SEP}", "[fi]=#{Y}"]],
    ['sudo ls -la', ["[sudo]=#{PRE}", "[ls]=#{G}", "[-la]=#{OPT1}"]],
    ['FOO=1 env BAR=2 ls', ["[FOO=1]=#{ASSIGN}", "[env]=#{PRE}", "[BAR=2]=#{ASSIGN}", "[ls]=#{G}"]],
    ['ls -l --all', ["[ls]=#{G}", "[-l]=#{OPT1}", "[--all]=#{OPT2}"]],
    [%q(echo 'a b' "c $HOME"), ["[echo]=#{G}", "['a b']=#{Y}", "[\"c $HOME\"]=#{Y}", "[$HOME]=#{C}"]],
    ['echo "abc', ["[echo]=#{G}", "[\"abc]=#{Y}"]],
    [%q(echo $'a\nb'), ["[echo]=#{G}", "[$'a\\nb']=#{Y}", "[\\n]=#{C}"]],
    ['echo $(echo x) y', ["[echo]=#{G}", "[$(]=#{M}", "[echo]=#{G}", "[)]=#{M}"]],
    ['echo ${HOME} $((1+2)) `ls`', ["[echo]=#{G}", "[${HOME}]=#{C}", "[$((1+2))]=#{C}", "[`]=#{M}", "[ls]=#{G}", "[`]=#{M}"]],
    ['ls # a comment', ["[ls]=#{G}", "[# a comment]=bold,fg=black"]],
    ['ls > out 2>&1', ["[ls]=#{G}", "[>]=#{Y}", "[2>&]=#{Y}"]],
    ['ls | grep x && echo y', ["[ls]=#{G}", "[|]=#{SEP}", "[grep]=#{G}", "[&&]=#{SEP}", "[echo]=#{G}"]],
    ['cat exists.txt nothere.txt', ["[cat]=#{G}", "[exists.txt]=#{UL}"]],
    ['cat exi', ["[cat]=#{G}", "[exi]=#{UL}"]],
    ['cat nothere', ["[cat]=#{G}"]],
    ['ls GG x', ["[ls]=#{G}", "[GG]=#{C}"]],
    ['ls *.txt', ["[ls]=#{G}", "[*.txt]=fg=blue"]],
    ["echo a\x16\nls dir", ["[echo]=#{G}", "[\n]=#{SEP}", "[ls]=#{G}", "[dir]=#{UL}"]],
    ['[[ -e x ]] && ls', ["[[[]=#{Y}", "[-e]=#{OPT1}", "[]]]=#{Y}", "[&&]=#{SEP}", "[ls]=#{G}"]],
    ['for i in 1 2; do echo $i; done', ["[for]=#{Y}", "[;]=#{SEP}", "[do]=#{Y}", "[echo]=#{G}", "[$i]=#{C}", "[;]=#{SEP}", "[done]=#{Y}"]],
    ['', []],
  ].freeze

  def test_highlight_table
    print "Test: line editor: highlight spans for #{CASES.size} command lines... "
    home, _, env = setup_home('pty')
    steps = CASES.flat_map { |keys, _| [CLEAR, keys, PROBE] }
    _, log = pty_session(home, env, steps)
    p = log.select { |l| l.start_with?('P|') }
    errs = []
    CASES.each_with_index do |(keys, want), i|
      got = spans(p[i])
      errs << "#{keys.inspect}: got #{got.inspect} want #{want.inspect}" unless got == want
    end
    errs << "probe count #{p.size}" unless p.size == CASES.size
    check('table', errs.empty?, errs.join("\n  "))
  end

  # With wayu's autosuggest on: the suggestion's entry (fg=8 after BUFFER)
  # survives the highlighter, and both keep their own entries.
  def test_with_autosuggest
    print "Test: together with autosuggest: suggestion still highlighted after BUFFER... "
    home, _, env = setup_home('pty_suggest', settings: "highlight = true\nautosuggest = true\n#{STYLES}\n")
    _, log = pty_session(home, env, ['print -r -- AL', PROBE, "\e[C", PROBE])
    p = log.select { |l| l.start_with?('P|') }
    e0 = entries(p[0])
    sug = e0.find { |e| e[3] == 'memo=wayu-suggest' }
    ok = spans(p[0]) == ["[print]=#{G}", "[-r]=#{OPT1}", "[--]=#{OPT2}"] &&
         sug && sug[0] == 14 && sug[1] == 14 + 'PHA-one-two'.size && sug[2] == 'fg=8' &&
         field(p[1], 'B') == 'print -r -- ALPHA-one-two' && !entries(p[1]).any? { |e| e[3] == 'memo=wayu-suggest' } &&
         spans(p[1]) == ["[print]=#{G}", "[-r]=#{OPT1}", "[--]=#{OPT2}"]
    check('suggest', ok, "log=#{log.inspect[0, 900]}")
  end

  # The active region is drawn on top (zle_highlight / standout); a
  # user's own region_highlight entry is kept.
  def test_region_and_user_entries
    print "Test: region shown on top; other region_highlight entries kept... "
    rc = <<~'ZSH'
      autoload -Uz add-zle-hook-widget
      _user_hl() { region_highlight=( "${(@)region_highlight:#*memo=user}" ); region_highlight+=( "0 1 bold, memo=user" ); }
      zle -N _user_hl
      add-zle-hook-widget zle-line-pre-redraw _user_hl
    ZSH
    home, _, env = setup_home('pty_region', rc_extra: rc)
    _, log = pty_session(home, env, ['ls -la', "\x00", "\e[D", "\e[D", PROBE, CLEAR, 'cd', PROBE])
    p = log.select { |l| l.start_with?('P|') }
    e0 = entries(p[0])
    reg = e0.find { |e| e[3] == 'memo=wayu-highlight' && e[2] == 'standout' }
    ok = reg && reg[0] == 4 && reg[1] == 6 && e0.index(reg) == e0.size - 1 - (e0.last[3] == 'memo=user' ? 1 : 0) &&
         e0.any? { |e| e[3] == 'memo=user' } && spans(p[0]).first(2) == ["[ls]=#{G}", "[-la]=#{OPT1}"] &&
         spans(p[1]) == ["[cd]=#{G}"] && entries(p[1]).count { |e| e[3] == 'memo=user' } == 1
    check('region', ok, "log=#{log.inspect[0, 900]}")
  end

  def test_with_defer_and_lazy
    print "Test: works with defer_plugins + lazy_compinit... "
    home, _, env = setup_home('pty_defer', settings: "highlight = true\ndefer_plugins = true\nlazy_compinit = true\n#{STYLES}\n")
    _, log = pty_session(home, env, ['sudo ls -la', PROBE])
    p = log.find { |l| l.start_with?('P|') }
    check('defer', spans(p) == ["[sudo]=#{PRE}", "[ls]=#{G}", "[-la]=#{OPT1}"], "log=#{log.inspect[0, 400]}")
  end

  # wayu's vi mode: highlighted in insert and normal mode.
  def test_vi_mode
    print "Test: vi mode: highlighted in insert and normal mode... "
    home, _, env = setup_home('pty_vi', prompt: "vi_mode = true\n")
    _, log = pty_session(home, env, ['nosuch | ls', PROBE, "\e", PROBE, 'bx', PROBE])
    p = log.select { |l| l.start_with?('P|') }
    want = ["[nosuch]=#{ERR}", "[|]=#{SEP}", "[ls]=#{G}"]
    ok = spans(p[0]) == want && field(p[1], 'K') == 'vicmd' && spans(p[1]) == want &&
         field(p[2], 'B') == 'nosuch | s' && spans(p[2]) == ["[nosuch]=#{ERR}", "[|]=#{SEP}", "[s]=#{ERR}"]
    check('vi', ok, "log=#{log.inspect[0, 700]}")
  end

  # Sourcing core again (wayu reload, re-sourced .zshrc) neither adds a
  # second hook nor duplicates entries.
  def test_resource_core
    print "Test: re-sourcing core.zsh keeps one hook and one set of entries... "
    rc = %(source "$HOME/.local/share/wayu/core.zsh"\n)
    home, _, env = setup_home('pty_resource', rc_extra: rc)
    _, log = pty_session(home, env, ['ls -la', PROBE])
    p = log.find { |l| l.start_with?('P|') }
    check('resource', spans(p) == ["[ls]=#{G}", "[-la]=#{OPT1}"] && field(p, 'W') == '1', "log=#{log.inspect[0, 400]}")
  end
end

if __FILE__ == $0
  HighlightTest.new.run
end
