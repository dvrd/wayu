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
    @shell_errors = []
    @inc_errors = []
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
        test_incremental_property
        test_continuation_lines
        test_multiline_and_wide
        test_paste_long_line
        test_undo_yank_search
        test_cursor_matching_bracket
        test_vi_text_objects
        test_widget_wrappers
        test_no_errors
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

  # Probe widget (^X^P) logging BUFFER + region_highlight to probe.log;
  # it also recomputes the highlighting from scratch and logs an INC line
  # when that differs from what the incremental run left. A redraw hook
  # logs the line during incremental search (S lines). ^X^R runs the
  # random-edit property test (_hl_prop, PROP line).
  PROBE_RC = <<~'ZSH'
    HISTFILE=$HOME/.zsh_history HISTSIZE=100 SAVEHIST=100
    setopt interactivecomments
    alias ll='ls -l'
    alias -g GG='| grep'
    myfn() { :; }
    cd $HOME/w
    _hl_state() {
      local k
      REPLY="${(j:;:)_wayu_hl_res}|${(j:;:)_wayu_hl_bres}|"
      for k in ${(ok)_wayu_hl_bpair}; do REPLY+="$k:$_wayu_hl_bpair[$k] "; done
    }
    _hl_probe() {
      local nl=$'\n' us=$'\x1f' inc REPLY
      local -a w
      zstyle -a zle-line-pre-redraw widgets w
      print -r -- "P|B=[${BUFFER//$nl/$us}]|K=$KEYMAP|C=$CURSOR|W=${#${(@M)w:#*_wayu_hl_redraw}}|H=[${(j:;:)region_highlight}]" >> $HOME/probe.log
      (( $+functions[_wayu_hl_redraw] )) || return 0
      _hl_state; inc=$REPLY
      _wayu_hl_key=
      _wayu_hl_redraw
      _hl_state
      [[ $inc == "$REPLY" ]] || print -r -- "INC|B=[${BUFFER//$nl/$us}]|inc=$inc|full=$REPLY" >> $HOME/probe.log
    }
    zle -N _hl_probe
    bindkey -M emacs '^X^P' _hl_probe
    bindkey -M viins '^X^P' _hl_probe
    bindkey -M vicmd '^X^P' _hl_probe
    bindkey -M emacs '^Xr' redo
    _hl_clear() { BUFFER= }
    zle -N _hl_clear
    bindkey -M emacs '^X^U' _hl_clear
    autoload -Uz up-line-or-beginning-search
    zle -N up-line-or-beginning-search
    bindkey -M emacs '^[[A' up-line-or-beginning-search
    # Random edits (insert / delete / kill / yank / yank-pop / undo / redo /
    # transpose) on each line of $HOME/corpus: after each, the incremental
    # result must equal a recompute from scratch.
    _hl_prop() {
      local -a lines snips
      local l inc REPLY first= nl=$'\n'
      local -i p q op r checks=0 fails=0
      lines=( "${(@ps:\x1e:)$(<$HOME/corpus)}" )
      snips=( a ' ' '"' "'" '(' ')' '{' '}' '[' ']' '$' '|' ';' '&&' '>' '<<EOF'$nl'x'$nl'EOF'$nl '`' '\' '#' '!' '=' '*' $nl \
              '$(' '${x}' ' | grep y' ' {a,b}' 'é' '🎉' ' !!' ' for i in 1; do ls; done' )
      RANDOM=4242
      for l in $lines; do
        BUFFER=$l CURSOR=$#l
        zle split-undo
        _wayu_hl_key=
        _wayu_hl_redraw
        for (( r = 0; r < 20; r++ )); do
          (( p = RANDOM % (${#BUFFER} + 1), op = RANDOM % 9 ))
          case $op in
            (0|1|2) CURSOR=p; LBUFFER+=${snips[RANDOM % ${#snips} + 1]} ;;
            (3) (( q = p + RANDOM % 8 )); BUFFER=${BUFFER[1,p]}${BUFFER[q+1,-1]}; CURSOR=p ;;
            (4) CURSOR=p; zle backward-kill-word ;;
            (5) CURSOR=p; zle yank; (( RANDOM % 2 )) && zle yank-pop ;;
            (6) zle undo ;;
            (7) zle redo ;;
            (8) CURSOR=p; zle transpose-words ;;
          esac
          zle split-undo
          _wayu_hl_redraw
          _hl_state; inc=$REPLY
          _wayu_hl_key=
          _wayu_hl_redraw
          _hl_state
          (( checks++ ))
          if [[ $inc != "$REPLY" ]]; then
            (( fails++ ))
            [[ -n $first ]] || first="${(q+)BUFFER} inc=$inc full=$REPLY"
          fi
        done
      done
      print -r -- "PROP|checks=$checks|fails=$fails|first=${first//$nl/ }" >> $HOME/probe.log
      BUFFER=
    }
    zle -N _hl_prop
    bindkey -M emacs '^X^R' _hl_prop
    precmd() { print -r -- "$HL_MARK" }
  ZSH

  def setup_home(name, settings: "highlight = true\n#{STYLES}\n", prompt: nil, plugin_json: false, rc_extra: '', zshenv_pre: '')
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
    File.write("#{home}/.zshenv", zshenv_pre + "source \"${WAYU_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/wayu}/init.zsh\"\n")
    File.write("#{home}/.zshrc", (prompt.to_s.include?('vi_mode = true') ? '' : "bindkey -e\n") + PROBE_RC + rc_extra)
    File.write("#{home}/.zsh_history", "print -r -- ALPHA-one-two\nprint -r -- older\n")
    corpus = File.readlines(File.expand_path('../highlight_diff/corpus.txt', __dir__), chomp: true)
                 .reject { |l| l.empty? || l.start_with?('%%') }.map { |l| l.gsub('␤', "\n") }
    File.write("#{home}/corpus", corpus.join("\x1e"))
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
        if s.is_a?(Array) # [:log, text, seconds]: wait until probe.log has text
          deadline = Time.now + s[2]
          read_until.call(nil, 0.2) until Time.now > deadline || (File.exist?(log) && File.read(log).include?(s[1]))
          next
        end
        w.write(s)
        read_until.call(nil, 0.3)
      end
      w.write("\x15exit\r")
      read_until.call(nil, 0.4)
      Process.kill('KILL', pid) rescue nil
      Process.wait(pid) rescue nil
    end
    lines = File.exist?(log) ? File.readlines(log, chomp: true) : []
    # Checked once at the end (test_no_errors): shell errors from wayu's
    # code on screen, incremental results that differ from a recompute.
    @shell_errors.concat(out.scan(/[^\r\n]*_wayu_[a-z_]+:\d+:[^\r\n]*/))
    @inc_errors.concat(lines.select { |l| l.start_with?('INC|') })
    [out, lines]
  end

  PROBE = "\x18\x10".freeze # ^X^P
  CLEAR = "\x15\x08\x15".freeze # ^U kill-whole-line; ^H ^U: the line above
  WIPE = "\x18\x15".freeze # ^X^U: BUFFER= (emacs)

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
  B1 = 'bold,fg=blue'.freeze  # bracket-level-1
  B2 = 'bold,fg=green'.freeze # bracket-level-2

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
    ['echo $(echo x) y', ["[echo]=#{G}", "[$(]=#{M}", "[echo]=#{G}", "[)]=#{M}", "[(]=#{B1}", "[)]=#{B1}"]],
    ['echo ${HOME} $((1+2)) `ls`', ["[echo]=#{G}", "[${HOME}]=#{C}", "[$((1+2))]=#{C}", "[`]=#{M}", "[ls]=#{G}", "[`]=#{M}",
                                    "[{]=#{B1}", "[}]=#{B1}"]],
    # Brackets by depth (pairs as they close), unmatched ones in red.
    ['echo {a,{b,c}} )', ["[echo]=#{G}", "[)]=#{Y}", "[{]=#{B2}", "[}]=#{B2}", "[{]=#{B1}", "[}]=#{B1}", "[)]=#{ERR}"]],
    ['echo !! !$ \!x', ["[echo]=#{G}", "[!!]=fg=blue", "[!$]=fg=blue"]],
    ['sudo !!', ["[sudo]=#{PRE}", "[!!]=fg=blue"]],
    ['for f (*.txt) ls', ["[for]=#{Y}", "[*.txt]=fg=blue", "[ls]=#{G}", "[(]=#{B1}", "[)]=#{B1}"]],
    ['noglob ls * && ls *', ["[noglob]=#{PRE}", "[ls]=#{G}", "[&&]=#{SEP}", "[ls]=#{G}", "[*]=fg=blue"]],
    ['command -v ls', ["[command]=#{PRE}", "[-v]=#{OPT1}", "[ls]=#{G}"]],
    ['local x=$HOME', ["[local]=#{G}", "[x=$HOME]=#{ASSIGN}", "[$HOME]=#{C}"]],
    ['{ ls } always { ls }', ["[{]=#{Y}", "[ls]=#{G}", "[}]=#{Y}", "[always]=#{Y}", "[{]=#{Y}", "[ls]=#{G}", "[}]=#{Y}",
                              "[{]=#{B1}", "[}]=#{B1}", "[{]=#{B1}", "[}]=#{B1}"]],
    ["'ls' x", ["['ls']=#{G}"]],
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

  # Random edits over the corpus of tests/highlight_diff (inserts, deletes,
  # kills, yank / yank-pop, undo / redo, transpose; real zle widgets): the
  # incremental result always equals a recompute from scratch.
  def test_incremental_property
    print "Test: incremental highlighting == full recompute over random edits... "
    home, _, env = setup_home('pty_prop')
    _, log = pty_session(home, env, ["\x18\x12", [:log, 'PROP|', 240]])
    prop = log.find { |l| l.start_with?('PROP|') }
    checks = prop.to_s[/checks=(\d+)/, 1].to_i
    check('prop', prop && checks > 2000 && prop.include?('|fails=0|'), "#{prop.inspect[0, 1500]}")
  end

  # Continuation lines (PS2): the lines entered so far are highlighted with
  # BUFFER, so its words keep their place (option, inside a string, inside
  # $(...)); heredoc lines are not highlighted.
  def test_continuation_lines
    print "Test: continuation lines (\\, unterminated quote / $(, heredoc) highlighted in context... "
    home, _, env = setup_home('pty_ps2')
    steps = ["ls \\\r", '-la', PROBE, "\x03",
             "echo \"abc\r", 'def" | ls', PROBE, "\x03",
             "echo $(\r", 'ls)', PROBE, "\x03",
             "cat <<EOF\r", 'a $HOME (', PROBE, "\x03"]
    _, log = pty_session(home, env, steps)
    p = log.select { |l| l.start_with?('P|') }
    errs = []
    errs << "\\: #{p[0]}" unless field(p[0], 'B') == '-la' && spans(p[0]) == ["[-la]=#{OPT1}"]
    errs << "quote: #{p[1]}" unless spans(p[1]) == ["[def\"]=#{Y}", "[|]=#{SEP}", "[ls]=#{G}"]
    errs << "$(: #{p[2]}" unless spans(p[2]) == ["[ls]=#{G}", "[)]=#{M}", "[)]=#{B1}"]
    errs << "heredoc: #{p[3]}" unless field(p[3], 'B') == 'a $HOME (' && spans(p[3]) == []
    check('ps2', errs.empty? && p.size == 4, errs.join("\n  ") + " log=#{log.inspect[0, 600]}")
  end

  # A multi-line buffer (^V^J) with a heredoc; wide characters and emoji
  # (offsets are characters: the spans stay on their words).
  def test_multiline_and_wide
    print "Test: multi-line buffer with heredoc; wide characters and emoji keep spans in place... "
    home, _, env = setup_home('pty_wide')
    nlk = "\x16\n"
    steps = [WIPE, "cat <<EOF#{nlk}a $HOME#{nlk}EOF#{nlk}ls -l", PROBE,
             WIPE, 'echo 日本語 🎉 | grep é && ls -l', PROBE,
             WIPE, 'echo "😀" $(echo 🎉) {é,ü}', PROBE,
             WIPE, "if true#{nlk}then#{nlk}  ls 🎉#{nlk}fi", PROBE]
    _, log = pty_session(home, env, steps)
    p = log.select { |l| l.start_with?('P|') }
    errs = []
    errs << "heredoc: #{spans(p[0])}" unless spans(p[0]) == ["[cat]=#{G}", "[<<]=#{Y}", "[ls]=#{G}", "[-l]=#{OPT1}"]
    errs << "wide: #{spans(p[1])}" unless spans(p[1]) == ["[echo]=#{G}", "[|]=#{SEP}", "[grep]=#{G}", "[&&]=#{SEP}", "[ls]=#{G}", "[-l]=#{OPT1}"]
    errs << "emoji: #{spans(p[2])}" unless spans(p[2]) == ["[echo]=#{G}", "[\"😀\"]=#{Y}", "[$(]=#{M}", "[echo]=#{G}", "[)]=#{M}",
                                                           "[(]=#{B1}", "[)]=#{B1}", "[{]=#{B1}", "[}]=#{B1}"]
    errs << "if: #{spans(p[3])}" unless spans(p[3]) == ["[if]=#{Y}", "[true]=#{G}", "[\n]=#{SEP}", "[then]=#{Y}", "[\n]=#{SEP}", "[ls]=#{G}", "[\n]=#{SEP}", "[fi]=#{Y}"]
    check('wide', errs.empty? && p.size == 4, errs.join("\n  "))
  end

  # A long line pasted (bracketed paste) is highlighted at once, then typing
  # at its end and in its middle stays cheap; a full recompute of it is
  # timed by the probe's caller below.
  def test_paste_long_line
    print "Test: bracketed paste of a ~4000-char line: highlighted, no errors, no lag... "
    home, _, env = setup_home('pty_paste', rc_extra: <<~'ZSH')
      zmodload zsh/datetime
      _hl_time() {
        local t=$EPOCHREALTIME
        _wayu_hl_key=
        _wayu_hl_redraw
        print -r -- "T|full=$(( (EPOCHREALTIME - t) * 1000 ))|len=$#BUFFER" >> $HOME/probe.log
      }
      zle -N _hl_time
      bindkey '^X^T' _hl_time
    ZSH
    words = (1..400).map { |i| i.even? ? "w#{i}" : "\"$H#{i}\"" }.join(' ')
    paste = "echo #{words} | grep -v x && ls -l > out.txt"
    steps = ["\e[200~#{paste}\e[201~", PROBE, ' y', PROBE, "\x01" + ("\e[C" * 300), 'zz', PROBE, "\x14\x14", PROBE, "\x18\x14"]
    _, log = pty_session(home, env, steps)
    p = log.select { |l| l.start_with?('P|') }
    t = log.find { |l| l.start_with?('T|') }
    ms = t.to_s[/full=([\d.]+)/, 1].to_f
    sp = spans(p[0])
    ok = field(p[0], 'B') == paste && sp.first == "[echo]=#{G}" && sp.include?('["$H1"]=fg=yellow') &&
         sp.include?("[|]=#{SEP}") && sp.include?("[out.txt]=#{UL}") == false && field(p[1], 'B') == paste + ' y' &&
         field(p[2], 'B').to_s.include?('zz') && p.size == 4 && t && ms < 2000
    puts "    (full highlight of #{t.to_s[/len=(\d+)/, 1]} chars: #{ms.round(1)} ms)" if ok
    check('paste', ok, "full=#{ms} p=#{p.size} spans=#{sp.first(4)} log=#{log.inspect[0, 300]}")
  end

  # Undo / redo, kill + yank / yank-pop, ^R incremental search (its match
  # stays underlined on top), history search widgets.
  def test_undo_yank_search
    print "Test: undo/redo, yank/yank-pop, ^R search, history-search-backward, up-line-or-beginning-search... "
    home, _, env = setup_home('pty_undo')
    steps = [CLEAR, 'ls -la /tmp', "\x17", PROBE, "\x1f", PROBE, "\x18r", PROBE,  # ^W, ^_ undo, redo
             CLEAR, 'echo aa bb', "\x17", "\x17", "\x19", "\ey", PROBE,           # kill x2, ^Y, M-y
             CLEAR, 'print', "\ep", PROBE,                                         # M-p history-search-backward
             CLEAR, 'print -r -- A', "\e[A", PROBE,                                # up-line-or-beginning-search
             CLEAR, ":\r", "\x12ALPHA", "\x05", PROBE]                                   # ^R ALPHA, ^E
    _, log = pty_session(home, env, steps)
    p = log.select { |l| l.start_with?('P|') }
    alpha = ["[print]=#{G}", "[-r]=#{OPT1}", "[--]=#{OPT2}"]
    errs = []
    errs << "kill: #{p[0]}" unless field(p[0], 'B') == 'ls -la ' && spans(p[0]) == ["[ls]=#{G}", "[-la]=#{OPT1}"]
    errs << "undo: #{p[1]}" unless field(p[1], 'B') == 'ls -la /tmp' && spans(p[1]) == ["[ls]=#{G}", "[-la]=#{OPT1}", "[/tmp]=#{UL}"]
    errs << "redo: #{p[2]}" unless field(p[2], 'B') == 'ls -la '
    errs << "yank: #{p[3]}" unless field(p[3], 'B').to_s.start_with?('echo ') && spans(p[3]).first == "[echo]=#{G}"
    errs << "M-p: #{p[4]}" unless field(p[4], 'B') == 'print -r -- older' && spans(p[4]) == alpha
    errs << "up: #{p[5]}" unless field(p[5], 'B') == 'print -r -- ALPHA-one-two' && spans(p[5]) == alpha
    errs << "^R: #{p[6]}" unless field(p[6], 'B') == 'print -r -- ALPHA-one-two' && spans(p[6]) == alpha
    check('undo', errs.empty? && p.size == 7, errs.join("\n  "))
  end

  # cursor-matchingbracket: with the cursor on a bracket, its pair.
  def test_cursor_matching_bracket
    print "Test: the bracket paired with the one under the cursor is marked... "
    home, _, env = setup_home('pty_match')
    _, log = pty_session(home, env, [CLEAR, 'echo $(ls) x', "\e[D" * 3, PROBE, "\e[D" * 3, PROBE, "\x05", PROBE])
    p = log.select { |l| l.start_with?('P|') }
    so = ->(l) { entries(l).select { |e| e[2] == 'standout' && e[3] == 'memo=wayu-highlight' }.map { |e| e[0, 2] } }
    ok = so.(p[0]) == [[6, 7]] && so.(p[1]) == [[9, 10]] && so.(p[2]) == []
    check('match', ok, "#{p.map { |l| so.(l) }.inspect} log=#{log.inspect[0, 400]}")
  end

  # vi mode: text objects and operators (ciw, cw, dd, x, p, u).
  def test_vi_text_objects
    print "Test: vi mode: ciw, cw, dd, u, p keep highlighting right... "
    home, _, env = setup_home('pty_vi_obj', prompt: "vi_mode = true\n")
    steps = ['echo foo bar', "\e", 'b', 'ciw', 'ls', PROBE, "\e", '0', 'cw', 'nosuch', PROBE,
             "\e", 'dd', PROBE, 'u', PROBE, '0', 'x', 'p', PROBE]
    _, log = pty_session(home, env, steps)
    p = log.select { |l| l.start_with?('P|') }
    errs = []
    errs << "ciw: #{p[0]}" unless field(p[0], 'B') == 'echo foo ls' && spans(p[0]) == ["[echo]=#{G}"]
    errs << "cw: #{p[1]}" unless field(p[1], 'B') == 'nosuch foo ls' && spans(p[1]) == ["[nosuch]=#{ERR}"]
    errs << "dd: #{p[2]}" unless field(p[2], 'B') == '' && spans(p[2]) == []
    errs << "u: #{p[3]}" unless field(p[3], 'B') == 'nosuch foo ls' && spans(p[3]) == ["[nosuch]=#{ERR}"]
    errs << "xp: #{p[4]}" unless field(p[4], 'B') == 'onsuch foo ls' && spans(p[4]) == ["[onsuch]=#{ERR}", '[n]=standout'] # pasted text
    check('vi-obj', errs.empty? && p.size == 5, errs.join("\n  "))
  end

  # Plugins that wrap zle widgets: one re-wrapping editing widgets before
  # every prompt (like fzf-tab / zsh-autosuggestions), one redefining
  # zle-line-pre-redraw and calling what was there (like zsh-vi-mode), and
  # one that defined zle-line-pre-redraw before wayu loaded.
  FAKE_WRAP = <<~'ZSH'
    _fw_wrap() {
      local w
      for w in self-insert backward-delete-char forward-char forward-word end-of-line yank accept-line; do
        [[ ${widgets[$w]-} == user:_fw_* ]] && continue
        zle -A $w _fw_orig_$w
        functions[_fw_$w]="(( FW_CALLS++ )); zle _fw_orig_$w -- \"\$@\""
        zle -N $w _fw_$w
      done
    }
    _fw_wrap
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd _fw_wrap
    typeset -g _fw_pre_raw=${widgets[zle-line-pre-redraw]#user:}
    _fw_pre() { (( FW_PRE++ )); [[ -n $_fw_pre_raw ]] && $_fw_pre_raw "$@"; return 0 }
    zle -N zle-line-pre-redraw _fw_pre
  ZSH
  EARLY_PRE = <<~'ZSH'
    if [[ -o interactive ]]; then
      _early_pre() { (( EARLY_PRE++ )); return 0 }
      zle -N zle-line-pre-redraw _early_pre
    fi
  ZSH

  def test_widget_wrappers
    print "Test: other plugins wrapping zle widgets / zle-line-pre-redraw: still highlighted... "
    home, _, env = setup_home('pty_wrap', rc_extra: FAKE_WRAP, zshenv_pre: EARLY_PRE)
    out, log = pty_session(home, env, ['ls -la', PROBE, "\x7f\x7fx", PROBE, CLEAR,
                                       "print -r -- \"FW=$FW_CALLS:$FW_PRE:$EARLY_PRE\"\r"])
    p = log.select { |l| l.start_with?('P|') }
    counts = out[/FW=(\d+):(\d+):(\d+)/] ? [$1, $2, $3].map(&:to_i) : []
    ok = spans(p[0]) == ["[ls]=#{G}", "[-la]=#{OPT1}"] && spans(p[1]) == ["[ls]=#{G}", "[-x]=#{OPT1}"] &&
         counts.size == 3 && counts.all?(&:positive?)
    check('wrap', ok, "counts=#{counts.inspect} log=#{log.inspect[0, 500]}")
  end

  # Every pty session above: no shell errors from wayu's code on screen,
  # and every probe's incremental result equals a recompute.
  def test_no_errors
    print "Test: no shell errors, incremental == full at every probe... "
    check('errors', @shell_errors.empty? && @inc_errors.empty?,
          "errors=#{@shell_errors.uniq.first(5).inspect} inc=#{@inc_errors.first(3).inspect}")
  end
end

if __FILE__ == $0
  HighlightTest.new.run
end
