#!/usr/bin/env ruby
# Integration tests for write integrity of wayu.toml / plugins.json:
#   OKAMI-201  [paths] order (PATH precedence) survives add/rm/clean
#   OKAMI-202  multi-line strings, arrays, ints and comments survive edits
#   OKAMI-203  atomic writes keep file mode + symlinks, leave no temp files
#   OKAMI-204  concurrent adds (alias, const, path, plugin) all land
#   OKAMI-240  one TOML parser: every command agrees on the same file
#   OKAMI-247  symlinked init.<ext> stays a symlink when wayu rewrites it

require 'open3'
require 'fileutils'
require 'shellwords'
require_relative 'test_helper'

class WriteIntegrityIntegrationTest
  include WayuTestHelper

  CONCURRENCY = 24

  def initialize
    setup_test_env
    @toml_file = "#{@config_dir}/wayu.toml"
  end

  def run
    puts "🔒 Testing write integrity..."
    puts

    begin
      build_project
      initialize_wayu

      test_path_order_preserved_across_add_rm_clean
      test_rich_values_survive_edits
      test_unterminated_value_aborts_without_writing
      test_mode_and_symlink_preserved
      test_concurrent_alias_adds
      test_concurrent_const_adds
      test_concurrent_path_adds
      test_concurrent_plugin_adds
      test_reader_parity_across_commands
      test_quoted_keys_listed_and_removed
      test_validate_names_the_line
      test_symlinked_init_stays_symlink
    ensure
      teardown_test_env
    end

    print_summary("WRITE INTEGRITY")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def check(name, ok, detail = nil)
    print "#{name}... "
    if ok
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  #{detail}" if detail
      @failed += 1
    end
  end

  def write_toml(content)
    File.write(@toml_file, content)
  end

  # Start `count` wayu processes from one shell with `&` (forking from Ruby
  # is slow enough to serialise them and hide the race), then wait for all.
  # Returns [[output, exit_code], ...].
  def run_parallel(count, env_extra = {})
    env = ENV.to_h.merge('HOME' => @tmp_home).merge(env_extra)
    out_dir = "#{@tmp_home}/parallel_out"
    FileUtils.rm_rf(out_dir)
    FileUtils.mkdir_p(out_dir)
    script = (1..count).map do |i|
      cmd = Shellwords.join([@wayu_bin, *yield(i)])
      "(#{cmd} > #{out_dir}/#{i}.log 2>&1; echo $? > #{out_dir}/#{i}.rc) &"
    end.join("\n") + "\nwait\n"
    system(env, 'sh', '-c', script)
    (1..count).map do |i|
      [File.read("#{out_dir}/#{i}.log"), File.read("#{out_dir}/#{i}.rc").to_i]
    end
  end

  def test_path_order_preserved_across_add_rm_clean
    zz = "#{@tmp_home}/zz_brew"
    aa = "#{@tmp_home}/aa_sys"
    mm = "#{@tmp_home}/mm_new"
    gone = "#{@tmp_home}/gone"
    [zz, aa, mm].each { |d| FileUtils.mkdir_p(d) }
    write_toml(<<~TOML)
      [shell]
      type = "zsh"

      [paths]
      zz_brew = "#{zz}" # first!
      gone = "#{gone}"
      aa_sys = "#{aa}"
    TOML

    _, s1 = run_wayu("path add #{mm}")
    _, s2 = run_wayu("--yes path clean")
    content = File.read(@toml_file)
    body = content[/\[paths\]\n(.*)\z/m, 1].to_s
    keys = body.lines.map { |l| l[/\A(\w+) =/, 1] }.compact
    check("Test 1: [paths] keeps declaration order across add + clean",
          s1.success? && s2.success? && keys == %w[zz_brew aa_sys mm_new] &&
            content.include?("zz_brew = \"#{zz}\" # first!"),
          "keys=#{keys.inspect}\n#{content}")

    _, s3 = run_wayu("path rm aa_sys")
    keys = File.read(@toml_file)[/\[paths\]\n(.*)\z/m, 1].to_s.lines.map { |l| l[/\A(\w+) =/, 1] }.compact
    check("Test 2: path rm keeps remaining order", s3.success? && keys == %w[zz_brew mm_new],
          "keys=#{keys.inspect}")
  end

  RICH = <<~'TOML'
    [shell]
    type = "zsh"

    [aliases]
    ll = "ls -l" # long listing

    [env]
    # certificate bundle
    CERT = """
    -----BEGIN-----
    abc=
    -----END-----"""
    LIST = [
      "a", # first
      "b",
    ]
    N = 42
  TOML

  def test_rich_values_survive_edits
    write_toml(RICH)
    _, s1 = run_wayu("const add NEWV 1")
    _, s2 = run_wayu("const add N 43")
    _, s3 = run_wayu("alias add ll 'ls -la'")
    _, s4 = run_wayu("const rm NEWV")
    expected = RICH.sub('N = 42', 'N = "43"').sub('ll = "ls -l" # long', 'll = "ls -la" # long')
    actual = File.read(@toml_file)
    check("Test 3: multi-line strings, arrays, ints, comments survive add/rm",
          [s1, s2, s3, s4].all?(&:success?) && actual == expected,
          "--- expected\n#{expected}--- actual\n#{actual}")

    _, s5 = run_wayu("const rm LIST")
    actual = File.read(@toml_file)
    check("Test 4: removing a multi-line array removes all of its lines",
          s5.success? && !actual.include?('"a", # first') && actual.include?("-----END-----\"\"\"\nN = \"43\""),
          actual)
  end

  def test_unterminated_value_aborts_without_writing
    broken = "[env]\nX = \"\"\"\nnever closed\n"
    write_toml(broken)
    _, status = run_wayu("const add Y 1")
    check("Test 5: unterminated multi-line value aborts with EXIT_DATAERR, file untouched",
          status.exitstatus == 65 && File.read(@toml_file) == broken,
          "exit=#{status.exitstatus}")
  end

  def test_mode_and_symlink_preserved
    write_toml("[shell]\ntype = \"zsh\"\n\n[env]\n")
    real = "#{@tmp_home}/dotfiles/wayu.toml"
    FileUtils.mkdir_p(File.dirname(real))
    FileUtils.mv(@toml_file, real)
    File.symlink(real, @toml_file)
    File.chmod(0o600, real)

    _, status = run_wayu("const add MODE_TEST 1")
    leftovers = Dir.children(@config_dir).select { |f| f.include?('.tmp.') } +
                Dir.children(File.dirname(real)).select { |f| f.include?('.tmp.') }
    check("Test 6: symlinked wayu.toml stays a symlink, mode kept, no temp files",
          status.success? && File.symlink?(@toml_file) &&
            File.read(real).include?('MODE_TEST = "1"') &&
            (File.stat(real).mode & 0o777) == 0o600 && leftovers.empty?,
          "symlink=#{File.symlink?(@toml_file)} mode=#{format('%o', File.stat(real).mode & 0o777)} leftovers=#{leftovers}")

    File.delete(@toml_file)
    FileUtils.mv(real, @toml_file)
  end

  def test_concurrent_alias_adds
    write_toml("[shell]\ntype = \"zsh\"\n\n[aliases]\n")
    results = run_parallel(CONCURRENCY) { |i| ['alias', 'add', "ca#{i}", "echo #{i}"] }
    landed = File.read(@toml_file).scan(/^ca\d+ = /).length
    check("Test 7: #{CONCURRENCY} concurrent alias adds all land",
          results.all? { |_, rc| rc.zero? } && landed == CONCURRENCY,
          "landed=#{landed}/#{CONCURRENCY}")
  end

  def test_concurrent_const_adds
    results = run_parallel(CONCURRENCY) { |i| ['const', 'add', "CC#{i}", i.to_s] }
    landed = File.read(@toml_file).scan(/^CC\d+ = /).length
    check("Test 8: #{CONCURRENCY} concurrent const adds all land",
          results.all? { |_, rc| rc.zero? } && landed == CONCURRENCY,
          "landed=#{landed}/#{CONCURRENCY}")
  end

  def test_concurrent_path_adds
    dirs = (1..CONCURRENCY).map { |i| "#{@tmp_home}/cp/p#{i}" }
    dirs.each { |d| FileUtils.mkdir_p(d) }
    results = run_parallel(CONCURRENCY) { |i| ['path', 'add', "cp#{i}=#{dirs[i - 1]}"] }
    landed = File.read(@toml_file).scan(/^cp\d+ = /).length
    check("Test 9: #{CONCURRENCY} concurrent path adds all land",
          results.all? { |_, rc| rc.zero? } && landed == CONCURRENCY,
          "landed=#{landed}/#{CONCURRENCY}")
  end

  # Local repos stand in for https://example.test/ via git's insteadOf.
  def test_concurrent_plugin_adds
    unless system('git --version > /dev/null 2>&1')
      check("Test 10: concurrent plugin adds (skipped: git missing)", true)
      return
    end
    n = 6
    repos = "#{@tmp_home}/repos"
    (1..n).each do |i|
      r = "#{repos}/cplug#{i}.git"
      FileUtils.mkdir_p(r)
      File.write("#{r}/cplug#{i}.plugin.zsh", "echo #{i}\n")
      system('git', '-C', r, 'init', '-q') &&
        system('git', '-C', r, 'add', '.') &&
        system('git', '-C', r, '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', 'init')
    end
    git_env = {
      'GIT_CONFIG_COUNT' => '1',
      'GIT_CONFIG_KEY_0' => "url.file://#{repos}/.insteadOf",
      'GIT_CONFIG_VALUE_0' => 'https://example.test/',
    }
    results = run_parallel(n, git_env) { |i| ['plugin', 'add', "https://example.test/cplug#{i}.git"] }
    json = File.exist?("#{@data_dir}/plugins.json") ? File.read("#{@data_dir}/plugins.json") : ''
    landed = (1..n).count { |i| json.include?("\"cplug#{i}\"") }
    check("Test 10: #{n} concurrent plugin adds all land in plugins.json",
          results.all? { |_, rc| rc.zero? } && landed == n,
          "landed=#{landed}/#{n}\n#{results.reject { |_, rc| rc.zero? }.map(&:first).join}")
  end
  # OKAMI-240 / CFG-14: valid TOML the old strict reader rejected (BOM,
  # multi-line array in [settings], quoted keys, int and multi-line [env]
  # values). validate, lists, TUI-facing parse and the generator agree, and
  # [paths] keep DECLARATION order (reverse-alphabetical here).
  def test_reader_parity_across_commands
    dirs = %w[zz mm aa].map { |d| "#{@tmp_home}/parity/#{d}" }
    dirs.each { |d| FileUtils.mkdir_p(d) }
    write_toml("\xEF\xBB\xBF" + <<~TOML)
      [shell]
      type = "zsh"

      [settings]
      autosuggestions_accept_keys = [
        "^Y", # ctrl-y
        "^E",
      ]

      [paths]
      zz = "#{dirs[0]}"
      mm = '#{dirs[1]}' # literal
      "aa" = "#{dirs[2]}"

      [aliases]
      "ll" = 'ls -la'
      glf = "git log --format='%h'"

      [env]
      N = 42
      CERT = """
      line1
      line2"""
    TOML
    out_v, s_v = run_wayu('toml validate')
    out_a, s_a = run_wayu('alias list --json')
    out_c, s_c = run_wayu('const list --json --reveal')
    _, s_b = run_wayu('build')
    sync = Dir.glob("#{@data_dir}/path_sync.zsh").map { |f| File.read(f) }.join
    core = File.read("#{@data_dir}/core.zsh") rescue ''
    order = dirs.map { |d| sync.index(d) || -1 }
    check("Test 11: one parser - validate, lists and generator agree (BOM, multi-line array, quoted keys)",
          s_v.success? && s_a.success? && s_c.success? && s_b.success? &&
            out_a.include?('"ll"') && out_a.include?("git log --format='%h'") &&
            out_c.include?('"N"') && out_c.include?('42') && out_c.include?('line1\nline2') &&
            core.include?('ll=') && order.all? { |i| i >= 0 } && order == order.sort,
          "validate=#{out_v.strip} order=#{order}\n#{out_a}\n#{out_c}")
  end

  # CFG-14: `"..` was emitted by the generator but `alias rm ..` said not
  # found; X-19: an escaped quote in a key is decoded everywhere.
  def test_quoted_keys_listed_and_removed
    write_toml(<<~'TOML')
      [shell]
      type = "zsh"

      [aliases]
      ".." = "cd .."
      "q\"k" = "echo quoted"
      ll = "ls"
    TOML
    out_l, _ = run_wayu('alias list --json')
    out_v, s_v = run_wayu('toml validate')
    _, s_r = run_wayu('alias rm ..')
    after = File.read(@toml_file)
    check("Test 12: quoted alias keys are listed decoded and removable",
          out_l.include?('".."') && out_l.include?('q\\"k') && !out_l.include?('\\"q') &&
            s_r.success? && !after.include?('".."') && after.include?('ll = "ls"') &&
            !s_v.success? && out_v.include?('Invalid alias'),
          "list=#{out_l}\nvalidate=#{out_v}\nafter=#{after}")
  end

  # X-19: `toml validate` used to exit 65 with no reason.
  def test_validate_names_the_line
    write_toml("[shell]\ntype = \"zsh\"\n\n[aliases]\nll = ls -la\n")
    out_v, s_v = run_wayu('toml validate')
    out_l, s_l = run_wayu('alias list --json')
    check("Test 13: validate names the bad line; lists keep the lenient reading",
          s_v.exitstatus == 65 && out_v.include?('line 5') && s_l.success? && out_l.include?('ls -la'),
          "validate=#{out_v}\nlist=#{out_l}")
  end

  # OKAMI-247 follow-up: a stow-style symlinked init.zsh that wayu upgrades
  # (temp file + rename) must keep its link; the target is rewritten.
  def test_symlinked_init_stays_symlink
    write_toml("[shell]\ntype = \"zsh\"\n\n[aliases]\n")
    init = "#{@data_dir}/init.zsh"
    real = "#{@tmp_home}/dotfiles/init.zsh"
    FileUtils.mkdir_p(File.dirname(real))
    old = File.read(File.join(__dir__, 'fixtures', 'init-4.4.5.zsh'))
    File.write(real, old)
    FileUtils.rm_f(init)
    File.symlink(real, init)
    _, status = run_wayu("alias add symt 'echo hi'")
    body = File.read(real)
    check("Test 14: symlinked init.zsh stays a symlink; its target is upgraded",
          status.success? && File.symlink?(init) && body != old &&
            body.include?('source "$WAYU_DATA_DIR/core.zsh"'),
          "symlink=#{File.symlink?(init)} upgraded=#{body != old}")
  end
end

WriteIntegrityIntegrationTest.new.run if __FILE__ == $0
