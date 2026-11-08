#!/usr/bin/env ruby
# Property test for generated shell quoting (OKAMI-174): random [aliases],
# [env] and [paths] values → `wayu build` → every generated file passes
# `<shell> -n` and sourcing init.<ext> in real zsh / bash / fish yields
# exactly the original values (env via the shell's own variable, aliases via
# the shell's alias table — fish via the arguments core.fish passes to
# `alias` — and PATH containing every directory).
#
# Env values follow the documented expansion rules (docs/UPGRADING.md):
# named references (`$NAME`, `${NAME}`; zsh/bash also `${NAME:-x}`) expand,
# every other `$` is literal. Operators that evaluate text (`${X@P}`,
# `${X[Y]}`, `${X:Y}`) must stay literal and never run a command — the
# `${X@P}` case only bites on bash >= 4.4, so every bash found is used.
#
# Reproduce a failure with WAYU_FUZZ_SEED=<seed printed below>;
# WAYU_FUZZ_ROUNDS sets the number of rounds (default 4).

require 'open3'
require 'fileutils'
require_relative 'test_helper'

class ShellFuzzTest
  include WayuTestHelper

  PER_ROUND = 15
  REF_VALUE = 'R-ok'
  # Printable ASCII except `$` (generated as its own token) plus UTF-8.
  LITERAL = ((32..126).map(&:chr) - ['$']) + %w[é ñ 日 本 🙂 ✓]
  # Chars that may follow a literal `$` without forming a name reference.
  AFTER_DOLLAR = LITERAL.reject { |c| c =~ /[A-Za-z_{]/ }
  PATH_CHARS = LITERAL - ['/', ':', '~']
  # Payloads that would run a command if an operator evaluated them.
  HOSTILE_ENV = <<~'TOML'
    FZ_CMD = '$(echo PWNED-cmd >&2)'
    FZ_SUB = 'a[$(echo PWNED-sub >&2)]'
    FZ_OP_P = '${FZ_CMD@P}'
    FZ_OP_IDX = '${FZ_CMD[FZ_SUB]}'
    FZ_OP_OFF = '${FZ_CMD:FZ_SUB}'
    FZ_OP_UP = '${FZ_CMD^}'
  TOML
  HOSTILE_WANT = {
    'FZ_CMD' => '$(echo PWNED-cmd >&2)', 'FZ_SUB' => 'a[$(echo PWNED-sub >&2)]',
    'FZ_OP_P' => '${FZ_CMD@P}', 'FZ_OP_IDX' => '${FZ_CMD[FZ_SUB]}',
    'FZ_OP_OFF' => '${FZ_CMD:FZ_SUB}', 'FZ_OP_UP' => '${FZ_CMD^}'
  }.freeze

  def initialize
    setup_test_env
    @seed = (ENV['WAYU_FUZZ_SEED'] || Random.new_seed % 1_000_000).to_i
    @rounds = (ENV['WAYU_FUZZ_ROUNDS'] || 4).to_i
    @rng = Random.new(@seed)
    @shells = detect_shells
  end

  def run
    puts "🚀 Testing generated shell quoting with random values (seed #{@seed})..."
    puts "   shells: #{@shells.map { |s| "#{s[:name]}=#{s[:exe]} #{s[:version]}" }.join(', ')}"
    puts

    begin
      build_project
      @rounds.times { |r| run_round(r) }
    ensure
      teardown_test_env
    end

    print_summary('shell fuzz')
    puts "(seed #{@seed})" if @failed > 0
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def detect_shells
    found = []
    zsh = which('zsh')
    found << { name: 'zsh', ext: 'zsh', exe: zsh, args: ['-f'] } if zsh
    bashes = ['/opt/homebrew/bin/bash', '/usr/local/bin/bash', which('bash'), '/bin/bash']
             .compact.select { |b| File.executable?(b) }.uniq { |b| File.realpath(b) }
    bashes.each { |b| found << { name: 'bash', ext: 'bash', exe: b, args: ['--norc', '--noprofile'] } }
    fish = ['/opt/homebrew/bin/fish', '/usr/local/bin/fish', which('fish'), '/usr/bin/fish']
           .compact.find { |f| File.executable?(f) }
    found << { name: 'fish', ext: 'fish', exe: fish, args: ['--no-config'] } if fish
    found.each do |s|
      out, = Open3.capture2e(s[:exe], '--version')
      s[:version] = out[/\d+\.\d+(\.\d+)?/]
    end
    found
  end

  def which(cmd)
    ENV.fetch('PATH', '').split(':').map { |d| File.join(d, cmd) }.find { |f| File.executable?(f) }
  end

  def pick(arr)
    arr[@rng.rand(arr.size)]
  end

  def literal(chars, min, max)
    Array.new(min + @rng.rand(max - min + 1)) { pick(chars) }.join
  end

  # Random env value as [source, zsh/bash expectation, fish expectation].
  def random_env
    src = +''
    sh = +''
    fish = +''
    (1 + @rng.rand(6)).times do
      case @rng.rand(10)
      when 0 # literal `$` + a char that can't start a name
        c = pick(AFTER_DOLLAR)
        [src, sh, fish].each { |s| s << '$' << c }
      when 1
        [src].each { |s| s << '${FZ_REF}' }
        sh << REF_VALUE; fish << REF_VALUE
      when 2
        src << '$FZ_REF/'; sh << "#{REF_VALUE}/"; fish << "#{REF_VALUE}/"
      when 3
        src << '${FZ_REF:-dflt}'; sh << REF_VALUE; fish << '${FZ_REF:-dflt}'
      when 4
        op = pick(['${FZ_CMD@P}', '${FZ_CMD[FZ_SUB]}', '${FZ_CMD:FZ_SUB}', '${FZ_REF^}', '$(echo PWNED-x >&2)',
                   '`echo PWNED-bt >&2`', '${(e)FZ_CMD}'])
        [src, sh, fish].each { |s| s << op }
      else
        l = literal(LITERAL, 1, 8)
        [src, sh, fish].each { |s| s << l }
      end
    end
    [src, sh, fish].each { |s| s << '$' } if @rng.rand(5).zero? # trailing `$`
    # A leading `~` / `~/` is rewritten to $HOME (documented); keep it out.
    if src.start_with?('~')
      [src, sh, fish].each { |s| s.prepend('x') }
    end
    [src, sh, fish]
  end

  def toml_string(s)
    '"' + s.gsub('\\') { '\\\\' }.gsub('"') { '\\"' } + '"'
  end

  def run_round(r)
    home = "#{@tmp_home}/round#{r}"
    FileUtils.rm_rf(home)
    FileUtils.mkdir_p(["#{home}/.config", "#{home}/p"])
    env = { 'HOME' => home, 'SHELL' => '/bin/zsh', 'PATH' => '/usr/bin:/bin:/usr/sbin:/sbin', 'ZDOTDIR' => nil,
            'WAYU_CONFIG' => nil, 'XDG_CONFIG_HOME' => nil, 'XDG_DATA_HOME' => nil, 'FZ_REF' => nil }
    @shells.map { |s| s[:name] }.uniq.each { |s| Open3.capture3(env, @wayu_bin, 'init', '--shell', s) }
    cfg = "#{home}/.config/wayu"

    # Alias bodies are stored verbatim (`$` included: it expands when the
    # alias runs, not when it is defined).
    aliases = Array.new(PER_ROUND) do |i|
      v = literal(LITERAL + ['$'], 1, 24)
      ["fz_a#{i}", v.strip.empty? ? "x#{v}" : v]
    end
    envs = Array.new(PER_ROUND) { |i| ["FZ_E#{i}", *random_env] }
    paths = Array.new(PER_ROUND) do |i|
      dir = "#{home}/p/#{i}#{literal(PATH_CHARS, 1, 12)}"
      FileUtils.mkdir_p(dir)
      ["fz_p#{i}", dir]
    end

    toml = +"[paths]\n"
    paths.each { |k, v| toml << "#{k} = #{toml_string(v)}\n" }
    toml << "\n[env]\nFZ_REF = \"#{REF_VALUE}\"\n" << HOSTILE_ENV
    envs.each { |k, v, _, _| toml << "#{k} = #{toml_string(v)}\n" }
    toml << "\n[aliases]\n"
    aliases.each { |k, v| toml << "#{k} = #{toml_string(v)}\n" }
    File.write("#{cfg}/wayu.toml", toml)
    _, berr, bst = Open3.capture3(env, @wayu_bin, 'build')
    unless bst.success?
      check("round #{r} build", false, "build failed: #{berr[0, 400]}")
      return
    end

    @shells.each do |sh|
      print "Test: round #{r}: random aliases/env/paths round-trip in #{sh[:name]} #{sh[:version]}... "
      syntax = Dir.glob("#{cfg}/*.#{sh[:ext]}").reject { |f| Open3.capture3(sh[:exe], '-n', f)[2].success? }
      out, err, st = Open3.capture3(env, sh[:exe], *sh[:args], '-c', probe(sh, cfg, envs, aliases))
      fields = out.b.split("\0", -1).map { |f| f.force_encoding('UTF-8') }
      problems = []
      problems << "syntax errors in #{syntax.map { |f| File.basename(f) }}" unless syntax.empty?
      problems << "exit #{st.exitstatus}" unless st.success?
      problems << "stderr: #{err[0, 300].inspect}" unless err.empty?
      want = []
      (envs.map { |k, _, s, f| [k, sh[:name] == 'fish' ? f : s] } + HOSTILE_WANT.to_a).each { |k, v| want << ["env #{k}", v] }
      aliases.each { |k, v| want << ["alias #{k}", v] }
      got_path = fields[want.size].to_s.split(':')
      want.each_with_index do |(label, v), i|
        problems << "#{label}: got #{fields[i].inspect}, want #{v.inspect}" unless fields[i] == v
      end
      paths.each { |k, d| problems << "path #{k} #{d.inspect} missing from PATH" unless got_path.include?(d) }
      check("round #{r} #{sh[:name]}", problems.empty?, problems.first(5).join("\n  "))
    end
  end

  # Prints every env value, alias body and finally PATH, NUL-separated.
  def probe(sh, cfg, envs, aliases)
    names = envs.map(&:first) + HOSTILE_WANT.keys
    anames = aliases.map(&:first)
    case sh[:name]
    when 'fish'
      # Capture what core.fish hands to `alias` (fish's own alias re-parses
      # the body as fish code, which random text is not).
      "function alias; set -g _fz_alias_$argv[1] $argv[2]; end; source '#{cfg}/init.fish'; " \
        "for v in #{names.join(' ')}; printf '%s\\0' \"$$v\"; end; " \
        "for a in #{anames.join(' ')}; set -l n _fz_alias_$a; printf '%s\\0' \"$$n\"; end; " \
        "printf '%s\\0' (string join : $PATH)"
    when 'zsh'
      "source '#{cfg}/init.zsh'; for v in #{names.join(' ')}; do printf '%s\\0' \"${(P)v}\"; done; " \
        "for a in #{anames.join(' ')}; do printf '%s\\0' \"${aliases[$a]}\"; done; printf '%s\\0' \"$PATH\""
    else
      # `alias name` prints a re-usable definition (BASH_ALIASES needs bash 4).
      "source '#{cfg}/init.bash'; for v in #{names.join(' ')}; do printf '%s\\0' \"${!v}\"; done; " \
        "for a in #{anames.join(' ')}; do d=$(alias \"$a\"); eval \"b=${d#*=}\"; printf '%s\\0' \"$b\"; done; " \
        "printf '%s\\0' \"$PATH\""
    end
  end

  def check(label, ok, detail)
    if ok
      puts '✓'; @passed += 1
    else
      puts '✗'; puts "  #{label}: #{detail}"; @failed += 1
    end
  end
end

if __FILE__ == $0
  ShellFuzzTest.new.run
end
