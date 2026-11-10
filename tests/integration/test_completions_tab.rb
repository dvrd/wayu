#!/usr/bin/env ruby
# Real TAB completion of wayu's own completion scripts (OKAMI-355):
# zsh through zsh/zpty (the generated _wayu autoloaded by compinit, TAB
# bound to complete-word, matches captured from compadd), bash through
# COMP_WORDS/COMP_CWORD as readline sets them (split at '=') under
# /bin/bash (3.2 on macOS), fish through `complete -C`. Each line is
# completed at its end; the candidates must include / exclude words.

require 'fileutils'
require 'open3'
require 'shellwords'
require 'timeout'
require_relative 'test_helper'

class CompletionsTabTest
  include WayuTestHelper

  # [line, must include, must not include]. A `--flag=` prefix is dropped
  # from candidates (fish offers `--lang=python`, bash/zsh `python`).
  CASES = [
    ['wayu ', %w[path alias secrets backup], %w[add gst]],
    ['wayu --dry-run al', %w[alias], %w[add]],
    ['wayu --shell bash alias rm ', %w[gst], %w[add]],
    ['wayu alias rm ', %w[gst], %w[add rm]],
    ['wayu alias --dry-run rm ', %w[gst], %w[add]],
    ['wayu alias rm gst ', [], %w[gst add]],
    ['wayu alias ', %w[add rm list], %w[gst]],
    ['wayu -y const get DY', %w[DYN_CONST], %w[SEC1]],
    ['wayu const get --yes DY', %w[DYN_CONST], []],
    ['wayu alias rm --', %w[--dry-run --yes --help], %w[--version --tui --lang]],
    ['wayu alias list --', %w[--json], []],
    ['wayu --', %w[--version --tui --dry-run], %w[--json]],
    ['wayu script new foo --l', %w[--lang], []],
    ['wayu script new foo --lang ', %w[swift python fish], %w[foo]],
    ['wayu script --lang ruby new foo --c', %w[--copy], []],
    ['wayu script new foo --lang=py', %w[python], %w[ruby]],
    ['wayu --shell ', %w[zsh bash fish], %w[path]],
    ['wayu path list --source ', %w[wayu external inactive all], []],
    ['wayu plugin search --category g', %w[git], %w[syntax]],
    ['wayu plugin search -c ', %w[git syntax prompt], []],
    ['wayu plugin add zsh-ab', %w[zsh-abbr], []],
    ['wayu init --template m', %w[minimal], %w[full]],
    ['wayu template apply d', %w[developer data-science], %w[minimal]],
    ['wayu backup restore ', %w[toml entries], %w[1]],
    ['wayu backup restore entries ', %w[1 2], %w[toml]],
    ['wayu backup --yes restore entries ', %w[1], []],
    ['wayu secrets run ', %w[SEC1], %w[DYN_CONST]],
    ['wayu secrets run SEC1 ', %w[SEC1], %w[DYN_CONST]],
    ['wayu secrets run SEC1 -- ech', %w[echo], %w[SEC1]],
    ['wayu completions fpath ', %w[list add rm], []],
    ['wayu doctor --', %w[--fix --json], []],
    ['wayu bogus ', [], %w[path add gst]],
  ].freeze

  def initialize
    setup_test_env
    @work = "#{@tmp_home}/tab"
  end

  def run
    puts '⇥ Testing TAB completion (zsh/bash/fish)...'
    puts

    begin
      build_project
      initialize_wayu
      setup_entries
      run_shell('zsh') { zsh_candidates }
      run_shell('bash') { bash_candidates }
      run_shell('fish') { fish_candidates }
    ensure
      teardown_test_env
    end

    print_summary('completions TAB')
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def env
    ENV.to_h.merge('HOME' => @tmp_home, '_WAYU_BIN' => @wayu_bin)
  end

  # gst alias, DYN_CONST plain and SEC1 secret constants (file key
  # backend in this temp HOME), and two entries.json backups.
  def setup_entries
    FileUtils.mkdir_p(@work)
    File.open("#{@config_dir}/wayu.toml", 'a') { |f| f.puts "\n[secrets]\nbackend = \"file\"" }
    run_wayu("alias add gst 'git status'")
    run_wayu('const add DYN_CONST 1')
    _, _, st = Open3.capture3(env, @wayu_bin, 'const', 'add', 'SEC1', '--secret', stdin_data: "v\n")
    abort 'const add --secret failed' unless st.success?
    backups = Dir.glob("#{@data_dir}/backup/entries.json.backup.*")
    abort "expected 2+ entries.json backups, got #{backups}" unless backups.size >= 2
  end

  def run_shell(name)
    print "#{name}: "
    unless system("command -v #{name} >/dev/null 2>&1")
      puts 'skipped (not installed)'
      return
    end
    got = Timeout.timeout(120) { yield }
    bad = []
    CASES.each do |line, want, reject|
      cands = (got[line] || []).map { |c| c.split("\t").first.to_s.sub(/\A--[a-z-]+=/, '') }
      missing = want - cands
      extra = reject & cands
      bad << "#{line.inspect}: missing #{missing} unexpected #{extra} (got #{cands.first(12)})" unless missing.empty? && extra.empty?
    end
    if bad.empty?
      puts "✓ (#{CASES.size} lines)"
      @passed += 1
    else
      puts '✗'
      bad.each { |b| puts "  #{b}" }
      @failed += 1
    end
  end

  # "@@ line" headers followed by candidates, one per line.
  def parse(out)
    res = {}
    cur = nil
    out.each_line do |l|
      l = l.chomp
      if l.start_with?('@@ ')
        cur = l[3..]
        res[cur] = []
      elsif cur && !l.empty?
        res[cur] << l
      end
    end
    res
  end

  def script(shell, file)
    out, = run_wayu("completions #{shell}")
    path = "#{@work}/#{file}"
    File.write(path, out)
    path
  end

  # COMP_WORDS as readline splits the line (spaces, '=' a word of its own).
  def comp_words(line)
    words = line.split(' ', -1)
    words.flat_map { |w| w.start_with?('-') && w.include?('=') ? w.split(/(=)/) : [w] }
  end

  def bash_candidates
    file = script('bash', 'wayu.bash')
    probe = +"source #{Shellwords.escape(file)}\n"
    CASES.each do |line, _, _|
      words = comp_words(line)
      probe << "COMP_WORDS=(#{words.map { |w| w.empty? ? "''" : Shellwords.escape(w) }.join(' ')})\n"
      probe << "COMP_CWORD=#{words.size - 1}\nCOMP_LINE=#{Shellwords.escape(line)}\nCOMP_POINT=${#COMP_LINE}\n"
      probe << "COMPREPLY=()\n_wayu_completion\necho #{Shellwords.escape("@@ #{line}")}\n"
      probe << "[ ${#COMPREPLY[@]} -gt 0 ] && printf '%s\\n' \"${COMPREPLY[@]}\"\n"
    end
    path = "#{@work}/probe.bash"
    File.write(path, probe)
    bash = File.executable?('/bin/bash') ? '/bin/bash' : 'bash'
    out, err, = Open3.capture3(env, bash, '--norc', '--noprofile', path)
    warn err unless err.empty?
    parse(out)
  end

  def fish_candidates
    file = script('fish', 'wayu.fish')
    cases = "#{@work}/cases.txt"
    File.write(cases, CASES.map(&:first).join("\n") + "\n")
    probe = "#{@work}/probe.fish"
    File.write(probe, <<~FISH)
      source $argv[1]
      while read -l line
          echo "@@ $line"
          complete -C "$line"
      end < $argv[2]
    FISH
    out, err, = Open3.capture3(env, 'fish', '--no-config', probe, file, cases)
    warn err unless err.empty?
    parse(out)
  end

  # An interactive `zsh -f` in a zpty: _wayu on fpath, compinit, compadd
  # wrapped to record the matches it adds, TAB bound to a widget that runs
  # complete-word, marks the end and clears the line.
  def zsh_candidates
    FileUtils.mkdir_p("#{@work}/fpath")
    File.write("#{@work}/fpath/_wayu", run_wayu('completions zsh').first)
    cases = "#{@work}/cases.txt"
    File.write(cases, CASES.map(&:first).join("\n") + "\n")
    init = "#{@work}/init.zsh"
    File.write(init, <<~'ZSH')
      PS1='' RPS1=''
      unsetopt beep autolist automenu
      fpath=($TAB_DIR/fpath $fpath)
      autoload -Uz compinit && compinit -u -D
      compadd() {
          if [[ ${@[1,(i)(-|--)]} == *-(O|A|D)\ * ]]; then
              builtin compadd "$@"; return $?
          fi
          local -a __hits
          builtin compadd -A __hits "$@"
          (( $#__hits )) && print -rl -- $__hits >>| $TAB_OUT
          builtin compadd "$@"
      }
      _tab() {
          : >>| $TAB_OUT
          zle complete-word
          print -r -- '<<DONE>>' >>| $TAB_OUT
          zle kill-whole-line
      }
      zle -N _tab
      bindkey '^I' _tab
      print READY
    ZSH
    driver = "#{@work}/driver.zsh"
    File.write(driver, <<~'ZSH')
      zmodload zsh/zpty zsh/zselect
      zpty -b z zsh -f -i
      zpty -w z "source ${(q)TAB_DIR}/init.zsh"
      zpty -r z junk '*READY*'
      for c in "${(@f)$(<$1)}"; do
          rm -f $TAB_OUT
          zpty -w -n z "$c"$'\t'
          integer k=0
          while ! { [[ -f $TAB_OUT ]] && grep -q '<<DONE>>' $TAB_OUT }; do
              zpty -rt z junk 2>/dev/null
              zselect -t 2
              (( ++k > 1500 )) && break
          done
          print -r -- "@@ $c"
          [[ -f $TAB_OUT ]] && grep -v '<<DONE>>' $TAB_OUT
      done
      zpty -d z
    ZSH
    zenv = env.merge('TAB_DIR' => @work, 'TAB_OUT' => "#{@work}/zsh.out")
    out, err, = Open3.capture3(zenv, 'zsh', '-f', driver, cases)
    warn err unless err.empty?
    parse(out)
  end
end

CompletionsTabTest.new.run if __FILE__ == $PROGRAM_NAME
