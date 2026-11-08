#!/usr/bin/env ruby
# Help and docs must match behavior (OKAMI-269).
#
# Every `wayu …` example printed by `wayu help`, by each command's --help, and
# written in README.md / docs/cli.md must parse: it may fail for lack of state (exit
# 65/66/78, …) but never with a usage error (exit 64), unless its comment
# documents the exit code ("# exit 65"), which must then match. A comment that
# names an entry ("# matches OPENAI_API_KEY") or calls the match an acronym
# must be what `search` reports. Synopsis lines (with <placeholders>) must name
# a real command and action. Each example runs in a fresh copy of an
# initialized, seeded HOME with a hermetic environment (no caller env, a `git`
# stub that fails, EDITOR=true), so help and docs can't drift again.
#
# Also: every unknown action word exits 64, `wayu toml` validates, and
# `wayu toml keys` lists the file's real top-level keys.

require 'open3'
require 'fileutils'
require 'shellwords'
require_relative 'test_helper'

class HelpExamplesIntegrationTest
  include WayuTestHelper

  ROOT = File.expand_path('../..', __dir__)
  TIMEOUT = 10 # seconds; a watcher still running by then has parsed fine
  EXIT_USAGE = 64
  PLACEHOLDER = /[<>\[\]|…]|\.\.\./.freeze
  SEARCH_WORDS = %w[search find f].freeze

  # Markdown docs whose examples are checked.
  DOCS = %w[README.md docs/cli.md].freeze

  # Inline-code mentions that name a command in prose rather than show a
  # complete invocation.
  DOC_INLINE_REFERENCES = [
    'wayu function add', # "wayu function add seeds a skeleton …" (needs NAME)
    'wayu vX.Y.Z',       # what --version prints
  ].freeze

  def initialize
    setup_test_env
    @pristine = Dir.mktmpdir('wayu_help_pristine_', '/tmp')
    @stub_bin = Dir.mktmpdir('wayu_help_bin_', '/tmp')
    at_exit do
      FileUtils.rm_rf(@pristine)
      FileUtils.rm_rf(@stub_bin)
    end
  end

  def run
    puts '📖 Testing help/README examples...'
    puts
    begin
      build_project
      write_git_stub
      prepare_pristine_home
      @commands = help_commands
      @actions = action_words
      examples = collect_help_examples + DOCS.flat_map { |d| collect_doc_examples(d) }
      check('found examples in help and README', examples.count { |e| !e[:synopsis] } > 50,
            "only #{examples.size}")
      examples.uniq { |e| [e[:cmd], e[:comment]] }.each do |e|
        e[:synopsis] ? check_synopsis(e) : run_example(e)
      end
      test_unknown_actions_exit_usage
      test_toml_default_validates
      test_toml_keys_lists_real_keys
    ensure
      teardown_test_env
    end
    print_summary('help examples')
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def check(name, ok, detail = '')
    print "#{name}... "
    if ok
      puts '✓'
      @passed += 1
    else
      puts '✗'
      puts "  #{detail}" unless detail.empty?
      @failed += 1
    end
  end

  # Minimal environment: nothing from the caller's env (secrets, a real
  # EDITOR, a real git) reaches the binary.
  def env_for(home)
    {
      'HOME' => home,
      'PATH' => "#{@stub_bin}:/usr/bin:/bin:/usr/sbin:/sbin",
      'SHELL' => '/bin/zsh',
      'TERM' => 'dumb',
      'NO_COLOR' => '1',
      'EDITOR' => 'true',
      'VISUAL' => 'true',
      'LANG' => 'en_US.UTF-8',
    }.merge(sanitizer_env)
  end

  def write_git_stub
    git = File.join(@stub_bin, 'git')
    File.write(git, "#!/bin/sh\necho 'git disabled in tests' >&2\nexit 128\n")
    File.chmod(0o755, git)
  end

  # Runs a documented command line through sh (so quoting and $HOME behave as
  # in a shell), with `wayu` replaced by the binary under test. Returns
  # [stdout+stderr, status], status nil when it was still running at TIMEOUT.
  def run_in(home, cmdline)
    bin = Shellwords.escape(@wayu_bin)
    script = cmdline.sub(/\Awayu(?=\s|\z)/, bin).gsub(/\$\(wayu(?=\s)/, "$(#{bin}")
    out = ''
    status = nil
    Open3.popen2e(env_for(home), '/bin/sh', '-c', script,
                  chdir: home, unsetenv_others: true, pgroup: true, in: File::NULL) do |_in, io, thr|
      reader = Thread.new { io.read }
      if thr.join(TIMEOUT)
        status = thr.value
      else
        begin
          Process.kill('TERM', -thr.pid)
          sleep 0.2
          Process.kill('KILL', -thr.pid)
        rescue Errno::ESRCH
          nil
        end
        thr.join
      end
      out = reader.value.to_s
    end
    [out.force_encoding('UTF-8'), status]
  end

  def wayu_pristine(args)
    run_in(@pristine, "wayu #{args}")
  end

  def prepare_pristine_home
    FileUtils.mkdir_p("#{@pristine}/.config")
    out, st = wayu_pristine('init --shell zsh')
    abort("init failed: #{out}") unless st&.success?
    # State the examples refer to, so most of them succeed outright.
    [
      'alias add ll "ls -la"', 'alias add gs "git status"', 'const add EDITOR nvim',
      'const add FIREWORKS_AI_API_KEY fw-test', 'const add OPENAI_API_KEY sk-test',
      'const add MY_VAR value', 'path add /usr/bin'
    ].each { |a| wayu_pristine(a) }
    File.write("#{@pristine}/.zshrc", "export FOO=1\nalias k=kubectl\n")
  end

  # Every command word `wayu help` lists (names and aliases).
  def help_commands
    out, = wayu_pristine('help')
    section = out[/COMMANDS:\n(.*?)\n\s*\n/m, 1].to_s
    section.lines.flat_map { |l| l.strip.split(/\s{2,}/).first.to_s.split(', ') }.reject(&:empty?)
  end

  # command word → action words offered by the generated fish completions
  # (the same WAYU_COMMAND_SPECS table the parser uses).
  def action_words
    out, = wayu_pristine('completions fish')
    words = Hash.new { |h, k| h[k] = [] }
    out.scan(/__fish_seen_subcommand_from ([^;']+); and test \(count \(commandline -opc\)\) -eq 2' -a '([^']+)'/) do |names, word|
      names.split.each { |n| words[n] << word }
    end
    words
  end

  def collect_help_examples
    sources = { 'wayu help' => wayu_pristine('help').first }
    @commands.each do |c|
      next if %w[help version].include?(c)
      sources["wayu #{c} --help"] = wayu_pristine("#{c} --help").first
    end
    check('every command has --help', sources.size > 15, "only #{sources.keys}")
    sources.flat_map do |src, text|
      text.lines.map { |l| example_from_line(l, src) }.compact
    end
  end

  # Fenced code lines and inline `wayu …` spans of a Markdown doc. In a table
  # row "| `wayu …` | 64 |" the number is the documented exit code.
  def collect_doc_examples(rel)
    examples = []
    in_code = false
    File.read(File.join(ROOT, rel)).lines.each_with_index do |l, i|
      if l.start_with?('```')
        in_code = !in_code
        next
      end
      where = "#{rel}:#{i + 1}"
      if in_code
        examples << example_from_line(l, where)
        next
      end
      next if l.start_with?('#') # a heading names the command it documents
      l.scan(/`(wayu [^`]+)`/).flatten.each do |span|
        next if DOC_INLINE_REFERENCES.include?(span)
        e = example_from_line(span, where)
        next unless e
        code = l[/\A\|\s*`#{Regexp.escape(span)}`\s*\|\s*(\d+)\s*\|/, 1]
        e[:comment] = "exit #{code}" if code
        examples << e
      end
    end
    examples.compact
  end

  # An example is a line (or a `$(wayu …)`) that starts with `wayu`. Help rows
  # put a description after 2+ spaces; ` # ` starts a comment. Lines with
  # placeholders (<name>, [args], a|b, ...) are synopses.
  def example_from_line(line, source)
    text = line.strip.sub(/\A\$\s+/, '')
    m = text.match(/\$\((wayu [^)]*)\)/)
    text = m[1] if m && !text.start_with?('wayu ')
    return nil unless text == 'wayu' || text.start_with?('wayu ')
    return nil if text.match?(/\Awayu [\w-]+ - /) # help title: "wayu path - Manage PATH"
    return nil if text.end_with?('.') && !text.include?('#') # a prose sentence

    cmd, comment = text.split(/\s+#\s?/, 2)
    cmd = cmd.split(/\s{2,}/).first.to_s.strip
    # `wayu path add/rm` in prose: an alternation, not a path argument.
    alternation = cmd.split.any? { |t| t.include?('/') && !t.match?(%r{\A['"]?[/~.$]|\Ahttps?://}) }
    { cmd: cmd, source: source, comment: comment.to_s,
      synopsis: alternation || cmd.match?(PLACEHOLDER) }
  end

  # A synopsis can't run, but its command and action words must exist.
  def check_synopsis(e)
    words = []
    e[:cmd].split.drop(1).each do |w|
      break if w.match?(PLACEHOLDER) || w.start_with?('-') || w.include?('/')
      words << w
    end
    return if words.empty?
    command, action = words
    ok = @commands.include?(command)
    ok &&= @actions[command].empty? || action.nil? || @actions[command].include?(action) if ok
    check("#{e[:source]}: #{e[:cmd]}", ok,
          ok ? '' : "unknown command/action '#{words.first(2).join(' ')}'")
  end

  def run_example(e)
    home = Dir.mktmpdir('wayu_help_ex_', '/tmp')
    begin
      FileUtils.cp_r("#{@pristine}/.", home)
      out, st = run_in(home, e[:cmd])
    ensure
      FileUtils.rm_rf(home)
    end
    name = "#{e[:source]}: #{e[:cmd]}"
    expected = e[:comment][/\bexit (\d+)\b/, 1]&.to_i
    if st.nil?
      check(name, !out.match?(/Unknown (command|option)|Unknown \w+ action/), "still running after #{TIMEOUT}s: #{out[0, 300]}")
    elsif st.signaled?
      check(name, false, "killed by signal #{st.termsig}: #{out[0, 300]}")
    elsif expected
      check(name, st.exitstatus == expected, "documented exit #{expected}, got #{st.exitstatus}: #{out[0, 300]}")
    else
      check(name, st.exitstatus != EXIT_USAGE, "usage error (exit 64): #{out[0, 400]}")
    end
    check_search_claims(e, out) if st && SEARCH_WORDS.include?(e[:cmd].split[1])
  end

  # "# matches OPENAI_API_KEY" / "# Acronym: FIREWORKS_AI_API_KEY" on a search
  # example: that entry is in the results, as an [acronym] match when the
  # comment says so.
  def check_search_claims(e, out)
    names = e[:comment].scan(/\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\b/)
    names.each do |n|
      found = out.lines.find { |l| l.include?(n) }
      check("#{e[:source]}: #{e[:cmd]} finds #{n}", found, out[0, 300])
      next unless found && e[:comment].match?(/acronym/i)
      check("#{e[:source]}: #{e[:cmd]} is an acronym match", found.include?('[acronym]'), found.strip)
    end
  end

  # An action word a command doesn't have is a usage error, never a silent
  # default (`toml bogus` / `hooks bogus` used to exit 0).
  def test_unknown_actions_exit_usage
    (@commands - %w[help version search find f]).each do |c|
      out, st = wayu_pristine("#{c} bogus-action")
      check("wayu #{c} bogus-action exits 64", st&.exitstatus == EXIT_USAGE,
            "exit #{st&.exitstatus}: #{out[0, 200]}")
    end
  end

  # `toml --help` says the default is validate.
  def test_toml_default_validates
    out, st = wayu_pristine('toml')
    out2, st2 = wayu_pristine('toml validate')
    check('wayu toml validates (same as toml validate)', st&.success? && st2&.success? && out == out2,
          "toml: #{out[0, 200]} / validate: #{out2[0, 200]}")
  end

  # `toml keys` lists the file's top-level keys and tables, not a fixed list.
  def test_toml_keys_lists_real_keys
    home = Dir.mktmpdir('wayu_help_keys_', '/tmp')
    begin
      FileUtils.cp_r("#{@pristine}/.", home)
      toml = "#{home}/.config/wayu/wayu.toml"
      File.write(toml, File.read(toml) + "\n[tools.zoxide]\ncmd = \"zoxide init zsh\"\n[custom]\nx = 1\n")
      expected = []
      in_root = true
      File.read(toml).each_line do |l|
        header = l[/\A\s*\[\[?\s*"?([A-Za-z0-9_-]+)/, 1]
        in_root = false if header
        key = header || (in_root ? l[/\A\s*([A-Za-z0-9_-]+)\s*=/, 1] : nil)
        expected << key if key && !expected.include?(key)
      end
      out, st = run_in(home, 'wayu toml keys')
      check('wayu toml keys lists the real top-level keys in file order',
            st&.success? && out.lines.map(&:strip) == expected && expected.include?('custom'),
            "expected #{expected}, got #{out.lines.map(&:strip)}")
    ensure
      FileUtils.rm_rf(home)
    end
  end
end

HelpExamplesIntegrationTest.new.run
