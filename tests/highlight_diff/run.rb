#!/usr/bin/env ruby
# Differential test: wayu's built-in zsh highlighter (src/highlight.zsh)
# against fast-syntax-highlighting (FSH, the pinned commit of
# tests/benchmark/compare.sh) over corpus.txt.
#
#   ruby tests/highlight_diff/run.rb            # compare with expected.txt
#   ruby tests/highlight_diff/run.rb --update   # rewrite expected.txt
#   FSH_DIR=/path/to/fsh-checkout ruby tests/highlight_diff/run.rb   # no clone
#
# Needs zsh >= 5.9 and (without FSH_DIR) git + network for the clone, which
# is cached under $TMPDIR. Not part of CI. Everything runs in a temp HOME.
#
# Both highlighters run in one interactive zsh (pty): a widget sets BUFFER
# to each corpus line and calls wayu's _wayu_hl_redraw (full recompute) and
# FSH's _zsh_highlight. Every style of both is set to "@<style name>", so
# each region_highlight entry names its style; the styles map to shared
# categories (CATEGORY_*), each character gets the category of the last
# entry covering it, and runs of characters where the two differ are the
# mismatches. FSH's chroma (per-command) highlighters and its secondary
# theme are off. The report lists every mismatch; expected.txt is the
# accepted one, so a change in either direction shows up as a diff.

require 'pty'
require 'io/console'
require 'fileutils'
require 'tmpdir'
require 'open3'

ROOT = File.expand_path('../..', __dir__)
HERE = __dir__

# wayu style -> category.
CATEGORY_WAYU = {
  'unknown-token' => 'unknown', 'reserved-word' => 'reserved', 'alias' => 'alias',
  'suffix-alias' => 'suffix-alias', 'global-alias' => 'global-alias', 'builtin' => 'builtin',
  'function' => 'function', 'command' => 'command', 'precommand' => 'precommand',
  'commandseparator' => 'separator', 'autodirectory' => 'autodirectory', 'path' => 'path',
  'path_prefix' => 'path', 'globbing' => 'glob', 'expansion' => 'expansion',
  'command-substitution-delimiter' => 'subst-delim', 'process-substitution-delimiter' => 'subst-delim',
  'back-quoted-argument-delimiter' => 'backquote-delim', 'single-hyphen-option' => 'option',
  'double-hyphen-option' => 'option', 'single-quoted-argument' => 'single-quoted',
  'double-quoted-argument' => 'double-quoted', 'dollar-quoted-argument' => 'dollar-quoted',
  'dollar-double-quoted-argument' => 'dq-expansion', 'back-double-quoted-argument' => 'dq-expansion',
  'back-dollar-quoted-argument' => 'dollar-quoted-escape', 'assign' => 'assign',
  'redirection' => 'redirection', 'comment' => 'comment', 'history-expansion' => 'history',
  'bracket-level-1' => 'bracket', 'bracket-level-2' => 'bracket', 'bracket-level-3' => 'bracket',
  'bracket-error' => 'unknown', 'cursor-matchingbracket' => 'bracket-match',
  'brace-expansion' => 'brace', 'numeric-fd' => 'fd', 'named-fd' => 'fd',
}.freeze

# FSH style -> category (nil: plain text).
CATEGORY_FSH = {
  'default' => nil, 'unknown-token' => 'unknown', 'reserved-word' => 'reserved', 'subcommand' => 'subcommand',
  'alias' => 'alias', 'suffix-alias' => 'suffix-alias', 'global-alias' => 'global-alias', 'builtin' => 'builtin',
  'function' => 'function', 'command' => 'command', 'precommand' => 'precommand',
  'commandseparator' => 'separator', 'hashed-command' => 'command', 'path' => 'path', 'path-to-dir' => 'path',
  'path_pathseparator' => 'path', 'globbing' => 'glob', 'globbing-ext' => 'glob',
  'history-expansion' => 'history', 'single-hyphen-option' => 'option', 'double-hyphen-option' => 'option',
  'back-quoted-argument' => 'backquote-delim', 'single-quoted-argument' => 'single-quoted',
  'double-quoted-argument' => 'double-quoted', 'dollar-quoted-argument' => 'dollar-quoted',
  'back-or-dollar-double-quoted-argument' => 'dq-expansion', 'back-dollar-quoted-argument' => 'dollar-quoted-escape',
  'assign' => 'assign', 'redirection' => 'redirection', 'comment' => 'comment', 'variable' => 'expansion',
  'mathvar' => 'math', 'mathnum' => 'math', 'matherr' => 'unknown', 'assign-array-bracket' => 'assign',
  'for-loop-variable' => 'for-loop', 'for-loop-operator' => 'for-loop', 'for-loop-number' => 'for-loop',
  'for-loop-separator' => 'for-loop', 'here-string-tri' => 'redirection', 'here-string-text' => 'here-string',
  'here-string-var' => 'dq-expansion', 'exec-descriptor' => 'redirection', 'case-input' => 'case',
  'case-parentheses' => 'reserved', 'case-condition' => 'case', 'paired-bracket' => 'bracket-match',
  'bracket-level-1' => 'bracket', 'bracket-level-2' => 'bracket', 'bracket-level-3' => 'bracket',
  'single-sq-bracket' => 'reserved', 'double-sq-bracket' => 'reserved', 'double-paren' => 'reserved',
  'correct-subtle' => 'subtle', 'incorrect-subtle' => 'unknown', 'subtle-separator' => 'subtle',
  'subtle-bg' => 'subtle', 'recursive-base' => nil,
}.freeze

def fsh_pin
  src = File.read("#{ROOT}/tests/benchmark/compare.sh")
  [src[/^FSH_REPO=(\S+)/, 1], src[/FSH_SHA=(\h+)/, 1]]
end

# A checkout of FSH at the pinned commit (FSH_DIR, or a cached clone).
def fsh_dir
  return File.expand_path(ENV['FSH_DIR']) if ENV['FSH_DIR']
  repo, sha = fsh_pin
  dir = File.join(Dir.tmpdir, "wayu-fsh-#{sha[0, 12]}")
  return dir if File.exist?("#{dir}/fast-syntax-highlighting.plugin.zsh")
  FileUtils.rm_rf(dir)
  ok = system('git', 'init', '-q', dir) &&
       system('git', '-C', dir, 'remote', 'add', 'origin', repo) &&
       system('git', '-C', dir, 'fetch', '-q', '--depth', '1', 'origin', sha) &&
       system('git', '-C', dir, '-c', 'advice.detachedHead=false', 'checkout', '-q', 'FETCH_HEAD')
  abort "could not fetch #{repo} #{sha} (set FSH_DIR to a checkout)" unless ok
  dir
end

def corpus
  File.readlines("#{HERE}/corpus.txt", chomp: true)
      .reject { |l| l.empty? || l.start_with?('%%') }
      .map { |l| l.gsub('␤', "\n") } +
    # Very long lines.
    ['echo ' + (1..120).map { |i| "word#{i}" }.join(' ') + ' | grep word7 > out.txt',
     'ls ' + (['-la "q s" $HOME *.txt'] * 25).join(' ') + ' && echo end']
end

# wayu's style names (src/highlight.odin) and the module with each style
# set to "@name".
def wayu_module
  names = File.read("#{ROOT}/src/highlight.odin").scan(/^\s*\{"([a-z0-9_-]+)", "[^"]*"\},/).flatten
  table = names.map { |n| "\n      #{n} '@#{n}'" }.join + "\n    "
  File.read("#{ROOT}/src/highlight.zsh").sub('@STYLES@', table)
end

DUMP_RC = <<~'ZSH'
  setopt interactivecomments
  PS1='> ' RPROMPT=
  alias ll='ls -l'
  alias -g GG='| grep'
  alias -s txt=cat
  myfn() { :; }
  cd $HOME/w
  source $HOME/wayu-hl.zsh
  FAST_WORK_DIR=$HOME/fsh-work
  mkdir -p $FAST_WORK_DIR && : > $FAST_WORK_DIR/secondary_theme.zsh
  source $FSH/fast-syntax-highlighting.plugin.zsh
  () {
    local k
    for k in ${(k)FAST_HIGHLIGHT}; do
      [[ $k == chroma-* && $FAST_HIGHLIGHT[$k] == →* ]] && unset "FAST_HIGHLIGHT[$k]"
    done
    for k in ${(k)FAST_HIGHLIGHT_STYLES}; do FAST_HIGHLIGHT_STYLES[$k]="@$k"; done
    FAST_HIGHLIGHT_STYLES[secondary]=
  }
  _diff_fsh() {
    emulate -LR zsh
    setopt extendedglob typesetsilent noshortloops
    local REPLY
    local -a reply
    -fast-highlight-init
    -fast-highlight-process "$PREBUFFER" "$BUFFER" 0
    if (( FAST_HIGHLIGHT[use_brackets] )); then
      _FAST_MAIN_CACHE=( $reply )
      -fast-highlight-string-process "$PREBUFFER" "$BUFFER"
    fi
    print -r -- "F$1 ${(pj:\x1f:)reply}" >> $HOME/dump
  }
  _diff_dump() {
    local -a lines
    local line us=$'\x1f'
    local -i i=0
    lines=( "${(@ps:\x1e:)$(<$HOME/corpus)}" )
    for line in "${lines[@]}"; do
      (( i++ ))
      BUFFER=$line CURSOR=$#line
      _wayu_hl_buf=$'\0'
      _wayu_hl_redraw
      print -r -- "W$i ${(pj:\x1f:)_wayu_hl_res}${_wayu_hl_bres:+$us}${(pj:\x1f:)_wayu_hl_bres}" >> $HOME/dump
      # What FSH's _zsh_highlight does for a changed line, keeping its
      # entries as built (zle would drop the "@style" attributes).
      _diff_fsh $i
    done
    print -r -- DONE >> $HOME/dump
    BUFFER=
  }
  zle -N _diff_dump
  bindkey -e
  bindkey -M emacs '^X^P' _diff_dump
  precmd() { print -r -- DIFF_READY }
ZSH

def run_shells(lines, fsh)
  home = Dir.mktmpdir('wayu-hldiff-')
  FileUtils.mkdir_p("#{home}/w/dir")
  File.write("#{home}/w/exists.txt", "x\n")
  File.write("#{home}/w/my file.txt", "x\n")
  File.write("#{home}/w/ünï.txt", "x\n")
  File.write("#{home}/w/script.sh", "#!/bin/sh\n")
  File.chmod(0o755, "#{home}/w/script.sh")
  File.write("#{home}/wayu-hl.zsh", wayu_module)
  File.write("#{home}/.zshrc", DUMP_RC)
  File.write("#{home}/corpus", lines.join("\x1e"))
  env = { 'HOME' => home, 'ZDOTDIR' => home, 'PATH' => '/usr/bin:/bin:/usr/sbin:/sbin', 'TERM' => 'xterm-256color',
          'FSH' => fsh, 'XDG_CACHE_HOME' => "#{home}/.cache", 'XDG_CONFIG_HOME' => "#{home}/.config",
          'LANG' => 'en_US.UTF-8', 'LC_ALL' => 'en_US.UTF-8', 'HISTFILE' => nil, 'PROMPT' => nil, 'PS1' => nil,
          'FAST_WORK_DIR' => nil, 'ZSH_HIGHLIGHT_MAXLENGTH' => nil }
  out = +''
  PTY.spawn(env, 'zsh', '-i') do |r, w, pid|
    r.winsize = [50, 200] rescue nil
    pump = lambda do |t, &done|
      deadline = Time.now + t
      until Time.now > deadline || done&.call
        next unless IO.select([r], nil, nil, 0.05)
        begin
          out << r.readpartial(1 << 16)
        rescue EOFError, Errno::EIO
          break
        end
      end
    end
    pump.call(15) { out.include?('DIFF_READY') }
    pump.call(0.5) # the line editor is up (raw mode)
    begin; w.write("\x18\x10"); rescue Errno::EIO; abort "shell exited: #{out[-3000..] || out}"; end
    pump.call(300) { File.exist?("#{home}/dump") && File.read("#{home}/dump").include?("DONE\n") }
    begin; w.write("exit\r"); rescue Errno::EIO; nil; end
    pump.call(1)
    Process.kill('KILL', pid) rescue nil
    Process.wait(pid) rescue nil
  end
  dump = File.exist?("#{home}/dump") ? File.read("#{home}/dump", encoding: 'UTF-8') : ''
  abort "no dump (shell output: #{out[-2000..] || out})" unless dump.include?("DONE\n")
  dump
ensure
  FileUtils.rm_rf(home) if home && !ENV["KEEP"]
end

# region_highlight entries -> per-character categories (last entry wins).
def paint(line, entries, map, who)
  cats = Array.new(line.length)
  entries.each do |e|
    m = e.match(/\A(\d+) (\d+) @([^,\s]+)/) or next
    style = m[3]
    abort "unmapped #{who} style #{style}" unless map.key?(style)
    (m[1].to_i...[m[2].to_i, line.length].min).each { |i| cats[i] = map[style] }
  end
  cats
end

def show(s)
  s.gsub("\n", '␤').gsub("\t", '⇥')
end

def diff_report(lines, dump)
  recs = {}
  dump.each_line(chomp: true) do |l|
    next unless l =~ /\A([WF])(\d+) ?(.*)\z/
    recs[[$1, $2.to_i]] = $3.split("\x1f")
  end
  report = []
  pairs = Hash.new(0)
  lines.each_with_index do |line, idx|
    w = paint(line, recs[['W', idx + 1]] || [], CATEGORY_WAYU, 'wayu')
    f = paint(line, recs[['F', idx + 1]] || [], CATEGORY_FSH, 'fsh')
    runs = []
    line.each_char.with_index do |ch, i|
      next if w[i] == f[i] || ch =~ /\s/ && (w[i].nil? || f[i].nil?)
      key = [w[i], f[i]]
      if runs.last && runs.last[:key] == key && runs.last[:end] == i
        runs.last[:end] = i + 1
      else
        runs << { key: key, start: i, end: i + 1 }
      end
    end
    next if runs.empty?
    report << "#{idx + 1}: #{show(line.length > 100 ? line[0, 100] + '…' : line)}"
    runs.each do |r|
      pairs[r[:key]] += 1
      report << "  [#{show(line[r[:start]...r[:end]])}] @#{r[:start]} wayu=#{r[:key][0] || '-'} fsh=#{r[:key][1] || '-'}"
    end
  end
  summary = pairs.sort_by { |k, v| [-v, k.map(&:to_s)] }.map { |(a, b), v| format('%4d  wayu=%s fsh=%s', v, a || '-', b || '-') }
  ["# #{lines.size} lines, #{report.count { |l| !l.start_with?(' ') }} with mismatches, #{pairs.values.sum} mismatched spans", *summary, '', *report].join("\n") + "\n"
end

lines = corpus
report = diff_report(lines, run_shells(lines, fsh_dir))
expected = "#{HERE}/expected.txt"
if ARGV.include?('--update')
  File.write(expected, report)
  puts report.lines.first
  exit 0
end
if File.exist?(expected) && File.read(expected) == report
  puts "highlight diff: matches expected.txt (#{report.lines.first.strip})"
  exit 0
end
File.write("#{Dir.tmpdir}/wayu-hldiff-report.txt", report)
puts "highlight diff: differs from expected.txt; report: #{Dir.tmpdir}/wayu-hldiff-report.txt"
system('diff', '-u', expected, "#{Dir.tmpdir}/wayu-hldiff-report.txt") if File.exist?(expected)
exit 1
