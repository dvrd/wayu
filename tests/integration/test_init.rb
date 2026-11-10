#!/usr/bin/env ruby
# Integration tests for init command and multi-shell support

require 'open3'
require 'fileutils'
require_relative 'test_helper'

class InitIntegrationTest
  include WayuTestHelper

  def initialize
    setup_test_env
  end

  def run
    puts "🚀 Testing init command and multi-shell integration..."
    puts

    begin
      build_project

      test_init_creates_directory_structure
      test_init_creates_config_files
      test_init_with_zsh
      test_init_with_bash
      test_config_file_templates
      test_init_file_orchestration
      test_shell_detection
      test_reinit_preserves_data
      test_dry_run_init
      test_help_command
      %w[zsh bash].each { |sh| test_generated_files_valid_syntax(sh); test_core_wiring(sh) }
      test_stale_init_is_resynced
      test_edited_init_is_preserved
      test_build_dry_run_writes_nothing
      test_large_toml_regenerates
      test_live_path_sync
      test_path_sync_status_and_nounset
      test_path_sync_managed_dirs
      test_regen_covers_all_initialized_shells
      test_paths_expanded_in_shell
      test_fish_paths_expanded_in_shell
      test_hand_edits_reach_open_shells
      test_rewrite_drops_stale_zwc
      test_prompt_opt_in_and_escaping
    ensure
      teardown_test_env
    end

    print_summary("init and multi-shell")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def run_wayu_with_env(args, extra_env = {})
    env = { 'HOME' => @tmp_home }.merge(extra_env)
    project_root = File.expand_path('../..', __dir__)
    stdout, stderr, status = Open3.capture3(env, "#{@wayu_bin} #{args}", chdir: project_root)
    stdout = stdout.force_encoding('UTF-8')
    stderr = stderr.force_encoding('UTF-8')
    [stdout + stderr, status]
  end

  def test_init_creates_directory_structure
    print "Test 1: Init creates directory structure... "

    # Clean up any existing config
    FileUtils.rm_rf(@config_dir) if Dir.exist?(@config_dir)
    FileUtils.rm_rf(@data_dir) if Dir.exist?(@data_dir)

    output, status = run_wayu("init")

    # Check that all required directories exist
    required_dirs = [
      @config_dir,
      @data_dir,
      "#{@data_dir}/functions",
      "#{@data_dir}/scripts",
      "#{@data_dir}/bin",
      "#{@data_dir}/completions",
      "#{@data_dir}/plugins"
    ]

    all_exist = required_dirs.all? { |dir| Dir.exist?(dir) }

    if status.success? && all_exist
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to create directory structure"
      puts "  Missing: #{required_dirs.reject { |d| Dir.exist?(d) }.join(', ')}"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_init_creates_config_files
    print "Test 2: Init creates config files... "

    required_files = [
      "#{@data_dir}/init.zsh",
      "#{@data_dir}/core.zsh",
      "#{@config_dir}/wayu.toml",
      "#{@config_dir}/tools.zsh"
    ]
    # No per-type shell files: entries.json holds paths, aliases and env.
    stale_files = %w[path aliases constants].map { |b| "#{@data_dir}/#{b}.zsh" }
    # The rc line init offers is the portable bootstrap (finds the data dir
    # itself); without a TTY it is printed.
    File.write("#{@tmp_home}/.zshrc", "# rc\n") unless File.exist?("#{@tmp_home}/.zshrc")
    rc, = run_wayu("init")
    FileUtils.rm_f("#{@tmp_home}/.zshrc")
    bootstrap = 'source "${WAYU_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/wayu}/init.zsh"'

    all_exist = required_files.all? { |file| File.exist?(file) } && stale_files.none? { |f| File.exist?(f) } &&
                rc.include?(bootstrap) && !File.read("#{@config_dir}/wayu.toml").include?('[paths]')

    if all_exist
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to create config files"
      puts "  Missing: #{required_files.reject { |f| File.exist?(f) }.join(', ')} rc_line=#{rc.include?(bootstrap)}"
      @failed += 1
    end
  end

  def test_init_with_zsh
    print "Test 3: Init with ZSH shell... "

    # Re-init with ZSH
    FileUtils.rm_rf(@config_dir) if Dir.exist?(@config_dir)
    FileUtils.rm_rf(@data_dir) if Dir.exist?(@data_dir)
    output, status = run_wayu_with_env("init", {"SHELL" => "/bin/zsh"})

    if status.success? && output.include?("zsh")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  ZSH init failed"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_init_with_bash
    print "Test 4: Init with Bash shell... "

    # Re-init with Bash
    FileUtils.rm_rf(@config_dir) if Dir.exist?(@config_dir)
    FileUtils.rm_rf(@data_dir) if Dir.exist?(@data_dir)
    output, status = run_wayu_with_env("init", {"SHELL" => "/bin/bash"})

    if status.success? && output.include?("bash")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Bash init failed"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_config_file_templates
    print "Test 5: Config file templates are valid... "

    # Reinitialize
    FileUtils.rm_rf(@config_dir) if Dir.exist?(@config_dir)
    FileUtils.rm_rf(@data_dir) if Dir.exist?(@data_dir)
    run_wayu("init")

    # Check that each file has proper shebang and structure (relaxed checks)
    files_to_check = {
      "#{@data_dir}/init.zsh" => ["source"],
      "#{@config_dir}/tools.zsh" => []  # May be empty
    }

    all_valid = files_to_check.all? do |file, required_content|
      next false unless File.exist?(file)
      if required_content.empty?
        true
      else
        content = File.read(file)
        required_content.all? { |req| content.include?(req) }
      end
    end

    if all_valid
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Some config file templates are invalid"
      @failed += 1
    end
  end

  def test_init_file_orchestration
    print "Test 6: Init file sources the compiled core only... "

    init_content = File.read("#{@data_dir}/init.zsh")
    core_content = File.read("#{@data_dir}/core.zsh")

    # init.zsh loads core.zsh; core.zsh sources tools.zsh. No per-type files.
    sources_core = init_content.include?("core.zsh")
    no_legacy = %w[path.zsh aliases.zsh constants.zsh].none? { |f| init_content.include?(f) }
    sources_tools = core_content.include?("tools.zsh")

    if sources_core && no_legacy && sources_tools
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Init file doesn't orchestrate all configs properly"
      @failed += 1
    end
  end

  def test_shell_detection
    print "Test 7: Shell type detection... "

    # Test ZSH detection
    output_zsh, _ = run_wayu_with_env("--shell zsh path list", {"SHELL" => "/bin/zsh"})

    # Test Bash detection
    output_bash, _ = run_wayu_with_env("--shell bash path list", {"SHELL" => "/bin/bash"})

    # Both should work without errors
    if !output_zsh.include?("error") && !output_bash.include?("error")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Shell detection issues"
      @failed += 1
    end
  end

  def test_reinit_preserves_data
    print "Test 8: Re-init keeps entries.json, wayu.toml and extra files byte for byte... "
    run_wayu('path add /tmp')
    run_wayu("alias add reinit_ll 'ls -la'")
    run_wayu('const add REINIT_X 1')
    files = ["#{@data_dir}/entries.json", "#{@config_dir}/wayu.toml", "#{@config_dir}/extra.zsh",
             "#{@config_dir}/tools.zsh"].select { |f| File.exist?(f) }
    before = files.to_h { |f| [f, File.read(f)] }
    output, status = run_wayu('init --no-color')
    after = files.to_h { |f| [f, File.read(f)] }
    entries = read_entries
    ok = status.success? && before.size >= 3 && before == after &&
         entries['paths'].any? { |e| e['dir'] == '/tmp' } &&
         entries['aliases'].any? { |e| e['name'] == 'reinit_ll' } &&
         entries['env'].any? { |e| e['name'] == 'REINIT_X' } &&
         output.include?('All config files already exist') && !output.include?('Created config file')
    check_result(ok, "changed: #{before.keys.reject { |f| before[f] == after[f] }}\n#{output}")
  end

  def test_dry_run_init
    print "Test 9: Dry-run init writes nothing; a real init counts every file it created... "
    FileUtils.rm_rf(@config_dir)
    FileUtils.rm_rf(@data_dir)
    output, status = run_wayu('--dry-run init --no-color')
    dry_ok = status.success? && output.include?('DRY RUN') &&
             !Dir.exist?(@config_dir) && !File.exist?("#{@data_dir}/init.zsh")
    real, = run_wayu('init --no-color')
    created = real.scan('Created config file:').size
    summary = real[/Created (\d+) config file\(s\)/, 1].to_i
    # OKAMI-357: the summary came before the last two files and said 3.
    count_ok = created >= 5 && summary == created &&
               real.rindex('Created config file:') < real.index(/Created \d+ config file/)
    check_result(dry_ok && count_ok, "dry_ok=#{dry_ok} created=#{created} summary=#{summary}\n#{output}")
  end

  def check_result(ok, detail)
    if ok
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  #{detail}"
      @failed += 1
    end
  end

  def test_help_command
    print "Test 10: Help command... "

    output, status = run_wayu("init --help")

    if status.success? && output.include?("wayu init - Initialize")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Help output incomplete"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  TRICKY_PATHS = { 'zz' => '$HOME/pz', 'aa' => '~/pa', 'mm' => '$HOME/p m', 'gone' => '/nonexistent/wayu/xyz' }.freeze
  TRICKY_ENV = {
    'GOPATH' => '$HOME/go', 'GOBIN' => '$GOPATH/bin', 'BREW' => '$HOMEBREW_PREFIX/x',
    'LEDGER_FILE' => '~/ledger.journal', 'QUOTED' => 'he said "hi" `whoami` $(id) back\\slash',
    'UNI' => 'héllo ✓', 'EMPTY' => ''
  }.freeze
  TRICKY_ALIASES = {
    'gl' => "git log --format='%h %s'", 'q' => %q(echo "double" and 'single' `tick` $HOME), 'u' => 'echo ünï'
  }.freeze

  TRICKY_TOML = <<~'TOML'
    [shell]
    type = "x"

    [tools]
    nvm = { kind = "nvm" }
    conda = { kind = "conda" }
    sdk = { kind = "lazy", init_script = "~/.sdk/init.sh", hook_commands = ["sdk"] }
    nosuchtoolxyz = { kind = "evalcache", args = "init x" }
    nosuchlogin = { kind = "evalcache", args = "init x", login_only = true }

    [prompt.contexts]
    kotlin = { format = "[K $version](magenta)", detect = ["*.kt", "build.gradle.kts"] }
  TOML

  # Build a fresh HOME for `shell`, write a tricky wayu.toml + entries and
  # regenerate. Returns [home, data dir (generated files), env].
  def generate_tricky(shell)
    home = "#{@tmp_home}/tricky_#{shell}"
    FileUtils.rm_rf(home)
    %w[pz pa p\ m].each { |d| FileUtils.mkdir_p("#{home}/#{d}") }
    FileUtils.mkdir_p("#{home}/.config")
    env = { 'HOME' => home, 'SHELL' => "/bin/#{shell}" }
    Open3.capture3(env, "#{@wayu_bin} init --shell #{shell}")
    cfg = "#{home}/.config/wayu"
    data = "#{home}/.local/share/wayu"
    File.write("#{cfg}/wayu.toml", TRICKY_TOML)
    write_entries(paths: TRICKY_PATHS, env: TRICKY_ENV, aliases: TRICKY_ALIASES, data: data)
    Open3.capture3(env, "#{@wayu_bin} build")
    [home, data, env]
  end

  # Every generated runtime file must parse with `<shell> -n`, and sourcing
  # core must reproduce the tricky values exactly.
  def test_generated_files_valid_syntax(shell)
    print "Test: generated #{shell} files pass #{shell} -n with tricky values... "
    home, cfg, env = generate_tricky(shell)
    files = Dir.glob("#{cfg}/*.#{shell}")
    bad = files.reject { |f| system(shell, '-n', f, out: File::NULL, err: File::NULL) }
    probe = %q{printf '%s\n' "$GOBIN" "$LEDGER_FILE" "$QUOTED" "$UNI" "[$EMPTY]" "$BREW"; alias gl}
    out, _, _ = Open3.capture3(env.merge('HOMEBREW_PREFIX' => '/hb'), shell, '-c', "source '#{cfg}/core.#{shell}' >/dev/null 2>&1; #{probe}")
    lines = out.force_encoding('UTF-8').lines.map(&:chomp)
    want = ["#{home}/go/bin", "#{home}/ledger.journal", 'he said "hi" `whoami` $(id) back\\slash',
            nil, '[]', '/hb/x']
    values_ok = lines[0] == want[0] && lines[1] == want[1] && lines[2] == want[2] &&
                lines[4] == want[4] && lines[5] == want[5] && lines[6].to_s.include?("%h %s")
    if files.size >= 3 && bad.empty? && values_ok
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  files=#{files.size} syntax_errors=#{bad.map { |f| File.basename(f) }}"
      puts "  got=#{lines.inspect}"
      @failed += 1
    end
  end

  # core sources plugins.<ext>; tools/extra are sourced exactly once across
  # core.<ext> (the one generated file); [paths] keep file order (not alphabetical).
  def test_core_wiring(shell)
    print "Test: #{shell} core sources plugins, tools/extra once, PATH in file order... "
    home, cfg, env = generate_tricky(shell)
    core = File.read("#{cfg}/core.#{shell}")
    all = %w[init core].map { |b| File.exist?("#{cfg}/#{b}.#{shell}") ? File.read("#{cfg}/#{b}.#{shell}") : '' }.join("\n")
    # OKAMI-284: core holds everything; no split files are generated.
    split_left = %w[lazy helpers login].select { |b| File.exist?("#{cfg}/#{b}.#{shell}") }
    plugins_ok = core.include?("#{cfg}/plugins.#{shell}\" ]; then source")
    extra_count = all.scan(/source "[^"]*extra\.#{shell}"/).size
    tools_count = all.scan(/source "[^"]*tools\.#{shell}"/).size
    # init.<ext> only sources core, which sources them (once each).
    fast_extra = File.read("#{cfg}/init.#{shell}").scan(/source "[^"]*(extra|tools)\.#{shell}"/).size
    # [paths] values are expanded by the shell: check the resulting PATH.
    out, = Open3.capture3(env.merge('PATH' => '/usr/bin:/bin'), shell, '-c',
                          ". '#{cfg}/core.#{shell}' >/dev/null 2>&1; echo \"$PATH\"")
    entries = out.strip.split(":").select { |e| e.start_with?(home) || e.include?("nonexistent") }
    path_line = entries.join(':')
    order_ok = entries[0, 3] == ["#{home}/pz", "#{home}/pa", "#{home}/p m"] &&
               entries.none? { |e| e.include?('nonexistent') }
    zsh_only_leak = shell == 'bash' && (core.include?('compinit') || core.include?('add-zsh-hook') || core.include?('helpers.zsh') || core.include?('lazy.zsh'))
    if plugins_ok && fast_extra == 0 && extra_count == 1 && tools_count == 1 && order_ok && !zsh_only_leak && split_left.empty?
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  plugins_ok=#{plugins_ok} fast_extra=#{fast_extra} extra=#{extra_count} tools=#{tools_count} order_ok=#{order_ok} zsh_leak=#{zsh_only_leak} split_left=#{split_left}"
      puts "  #{path_line}"
      @failed += 1
    end
  end

  # An untouched init.zsh written from the previous template
  # (fixtures/init-prev.zsh) is rewritten on regen, after a backup of it.
  def test_stale_init_is_resynced
    print "Test: stale init.zsh is rewritten on regeneration (with backup)... "
    _, cfg, env = generate_tricky('zsh')
    init = "#{cfg}/init.zsh"
    old = File.read(File.join(__dir__, 'fixtures', 'init-prev.zsh'))
    File.write(init, old)
    _, err, = Open3.capture3(env, "#{@wayu_bin} alias add zz 'echo hi'")
    body = File.read(init)
    backups = Dir.glob("#{cfg}/backup/init.zsh.backup.*")
    if body != old && body.include?('source "$WAYU_DATA_DIR/core.zsh"') &&
       backups.any? { |b| File.read(b) == old } && !err.include?('local edits')
      puts "✓"; @passed += 1
    else
      puts "✗"; puts "  resynced=#{body != old} backups=#{backups.size} err=#{err.strip[0, 200]}"; @failed += 1
    end
  end

  # OKAMI-235: an init.zsh the user edited is never rewritten; wayu warns on
  # stderr instead (stdout stays clean).
  def test_edited_init_is_preserved
    print "Test: user-edited init.zsh is kept, with a warning... "
    _, cfg, env = generate_tricky('zsh')
    init = "#{cfg}/init.zsh"
    edited = File.read(init) + "export MY_CUSTOM=1\n"
    File.write(init, edited)
    _, err1, st1 = Open3.capture3(env, "#{@wayu_bin} alias add qq 'echo q'")
    out2, err2, = Open3.capture3(env, "#{@wayu_bin} build")
    if st1.success? && File.read(init) == edited && err1.include?('local edits') &&
       err2.include?('local edits') && !out2.include?('local edits')
      puts "✓"; @passed += 1
    else
      puts "✗"; puts "  kept=#{File.read(init) == edited} err1=#{err1.strip[0, 200]}"; @failed += 1
    end
  end

  # `wayu path add/rm` must reach an already-open shell at its next prompt via
  # the path_sync prompt hook, and `wayu` must NOT be shadowed by a shell
  # function (the old wrapper showed up first in `where`/`type`).
  def test_live_path_sync
    %w[zsh bash].each do |sh|
      print "Test: live PATH sync via prompt hook (#{sh})... "
      home = "#{@tmp_home}/sync_#{sh}"
      d1 = "#{home}/d1"
      d2 = "#{home}/my dir"
      FileUtils.mkdir_p([d1, d2, "#{home}/.config"])
      env = { 'HOME' => home }
      Open3.capture3(env, @wayu_bin, 'init', '--shell', sh)
      Open3.capture3(env, @wayu_bin, '--shell', sh, 'path', 'add', d1)
      script = <<~SH
        . "$HOME/.local/share/wayu/core.#{sh}"
        has() { case ":$PATH:" in *":$1:"*) echo y ;; *) echo n ;; esac; }
        r="$(has "$D1")"
        "$W" --shell #{sh} path add "$D2" >/dev/null 2>&1; _wayu_paths_sync
        r="$r$(has "$D2")"
        "$W" --shell #{sh} path rm "$D1" --yes >/dev/null 2>&1; _wayu_paths_sync
        r="$r$(has "$D1")$(has "$D2")"
        before="$PATH"; _wayu_paths_sync; [ "$before" = "$PATH" ] && r="${r}s"
        type wayu 2>/dev/null | grep -q function && r="${r}F"
        echo "$r"
      SH
      out, err, st = Open3.capture3(env.merge('W' => @wayu_bin, 'D1' => d1, 'D2' => d2), sh, '-c', script)
      # expected: d1 on start (y), d2 after add (y), d1 gone + d2 kept (ny), idle no-op (s), no function
      if st.success? && out.strip == 'yynys' && err.strip.empty?
        puts "✓"; @passed += 1
      else
        puts "✗"; puts "  out=#{out.strip.inspect} err=#{err.strip[0, 300]}"; @failed += 1
      end
    end
  end

  # Fresh HOME with `shells` initialised and `dirs` created (not added).
  def sync_home(name, shells, dirs = [])
    home = "#{@tmp_home}/#{name}"
    FileUtils.rm_rf(home)
    FileUtils.mkdir_p(["#{home}/.config"] + dirs.map { |d| "#{home}/#{d}" })
    env = { 'HOME' => home, 'PATH' => '/usr/bin:/bin', 'W' => @wayu_bin }
    shells.each { |sh| Open3.capture3(env, @wayu_bin, 'init', '--shell', sh) }
    [home, env]
  end

  # OKAMI-209: the bash PROMPT_COMMAND hook must not clobber $? for prompt
  # commands that run after it (git-prompt, starship, custom PS1 functions).
  # OKAMI-210: init + hook must work under `set -u` / `setopt nounset`.
  def test_path_sync_status_and_nounset
    { '/bin/bash' => 'bash', '/bin/zsh' => 'zsh' }.each do |bin, sh|
      print "Test: path sync keeps $? and works under nounset (#{bin})... "
      home, env = sync_home("nounset_#{sh}", [sh], %w[d1 d2])
      Open3.capture3(env, @wayu_bin, '--shell', sh, 'path', 'add', "#{home}/d1")
      strict = sh == 'zsh' ? 'setopt nounset' : 'set -u'
      script = <<~SH
        #{strict}
        __p() { echo "LAST=$?"; }
        PROMPT_COMMAND=__p
        . "$HOME/.local/share/wayu/init.#{sh}"
        has() { case ":$PATH:" in *":$1:"*) echo y ;; *) echo n ;; esac; }
        echo "start=$(has "$HOME/d1")"
        "$W" --shell #{sh} path add "$HOME/d2" >/dev/null 2>&1
        false; _wayu_paths_sync; echo "sync_rc=$?"
        echo "added=$(has "$HOME/d2")"
      SH
      script += "false; eval \"$PROMPT_COMMAND\"\n(exit 7); eval \"$PROMPT_COMMAND\"\n" if sh == 'bash'
      out, err, st = Open3.capture3(env, bin, sh == 'zsh' ? '-fc' : '-c', script)
      want = %w[start=y sync_rc=1 added=y]
      want += %w[LAST=1 LAST=7] if sh == 'bash'
      if st.success? && err.strip.empty? && out.lines.map(&:strip) == want
        puts "✓"; @passed += 1
      else
        puts "✗"; puts "  out=#{out.lines.map(&:strip).inspect} err=#{err.strip[0, 300]}"; @failed += 1
      end
    end
  end

  # OKAMI-211: removing a wayu entry must not strip a dir that was already on
  # PATH before wayu (system / path_helper provided), and a dir added in an
  # open shell lands where a new shell would put it (after the previous
  # [paths] entry), not in front of higher-priority entries.
  def test_path_sync_managed_dirs
    { '/bin/bash' => 'bash', '/bin/zsh' => 'zsh' }.each do |bin, sh|
      print "Test: path sync keeps system dirs + [paths] order (#{bin})... "
      home, env = sync_home("managed_#{sh}", [sh], %w[a b c s])
      write_entries(paths: { 'a' => "#{home}/a", 'b' => "#{home}/b", 's' => "#{home}/s" },
                    data: "#{home}/.local/share/wayu")
      Open3.capture3(env, @wayu_bin, '--shell', sh, 'build')
      script = <<~SH
        . "$HOME/.local/share/wayu/core.#{sh}"
        show() { echo "$PATH" | sed "s|$HOME/||g"; }
        show
        "$W" --shell #{sh} path rm "$HOME/s" --yes >/dev/null 2>&1; _wayu_paths_sync; show
        "$W" --shell #{sh} path rm "$HOME/a" --yes >/dev/null 2>&1; _wayu_paths_sync; show
        "$W" --shell #{sh} path add "$HOME/c" >/dev/null 2>&1; _wayu_paths_sync; show
      SH
      out, err, st = Open3.capture3(env.merge('PATH' => "/usr/bin:#{home}/s:/bin"), bin, '-c', script)
      want = ['a:b:s:/usr/bin:/bin', 'a:b:s:/usr/bin:/bin', 'b:s:/usr/bin:/bin', 'b:c:s:/usr/bin:/bin']
      if st.success? && out.lines.map(&:strip) == want
        puts "✓"; @passed += 1
      else
        puts "✗"; puts "  out=#{out.lines.map(&:strip).inspect} err=#{err.strip[0, 300]}"; @failed += 1
      end
    end
  end

  # OKAMI-212: a write from a process whose $SHELL is another shell must still
  # regenerate every initialized shell's files (bash + fish here), so open
  # and new shells of every kind see the change.
  def test_regen_covers_all_initialized_shells
    print "Test: regen refreshes every initialized shell (SHELL=zsh, bash+fish set up)... "
    home, env = sync_home('allshells', %w[bash fish], %w[d1 d2])
    Open3.capture3(env, @wayu_bin, '--shell', 'bash', 'path', 'add', "#{home}/d1")
    script = <<~SH
      . "$HOME/.local/share/wayu/core.bash"
      SHELL=/bin/zsh "$W" path add "$HOME/d2" >/dev/null 2>&1
      SHELL=/bin/zsh "$W" alias add zzq 'echo hi' >/dev/null 2>&1
      _wayu_paths_sync
      case ":$PATH:" in *":$HOME/d2:"*) echo open=y ;; *) echo open=n ;; esac
    SH
    out, err, = Open3.capture3(env, '/bin/bash', '-c', script)
    cfg = "#{home}/.local/share/wayu"
    core_bash = File.read("#{cfg}/core.bash")
    core_fish = File.read("#{cfg}/core.fish")
    ok = out.strip == 'open=y' && core_bash.include?('alias zzq=') &&
         File.read("#{cfg}/path_sync.bash").include?("#{home}/d2") &&
         core_fish.include?('zzq') && core_fish.include?('d2')
    if ok
      puts "✓"; @passed += 1
    else
      puts "✗"; puts "  out=#{out.strip} err=#{err.strip[0, 300]} bash_alias=#{core_bash.include?('alias zzq=')} fish=#{core_fish.include?('zzq')}/#{core_fish.include?('d2')}"; @failed += 1
    end
  end

  # OKAMI-213 (GEN-18): PATH entries are expanded by the shell, after the
  # constants: `$GOPATH/bin` uses the GOPATH constant, an unset var drops the
  # entry (no bare "/bin"), and a dir created after `wayu build` shows up in
  # new shells.
  def test_paths_expanded_in_shell
    { '/bin/bash' => 'bash', '/bin/zsh' => 'zsh' }.each do |bin, sh|
      print "Test: PATH entries expanded in-shell after constants (#{bin})... "
      home, env = sync_home("inshell_#{sh}", [sh], %w[go/bin])
      write_entries(env: { 'GOPATH' => '$HOME/go' },
                    paths: { 'gobin' => '$GOPATH/bin', 'cargo' => '${NO_SUCH_WAYU_VAR}/bin', 'later' => '~/later' },
                    data: "#{home}/.local/share/wayu")
      _, _, st = Open3.capture3(env, @wayu_bin, '--shell', sh, 'build')
      probe = %(. "$HOME/.local/share/wayu/core.#{sh}" >/dev/null 2>&1; echo "$PATH")
      first, = Open3.capture3(env.merge('PATH' => '/usr/bin'), bin, '-c', probe)
      FileUtils.mkdir_p("#{home}/later")
      second, = Open3.capture3(env.merge('PATH' => '/usr/bin'), bin, '-c', probe)
      a = first.strip.split(':')
      b = second.strip.split(':')
      if st.success? && a == ["#{home}/go/bin", '/usr/bin'] && b == ["#{home}/go/bin", "#{home}/later", '/usr/bin']
        puts "✓"; @passed += 1
      else
        puts "✗"; puts "  exit=#{st.exitstatus} first=#{a.inspect} second=#{b.inspect}"; @failed += 1
      end
    end
  end

  # Same contract for core.fish (expanded by fish, guarded per variable).
  def test_fish_paths_expanded_in_shell
    print "Test: PATH entries expanded in-shell after constants (fish)... "
    fish = ENV['PATH'].split(':').map { |d| "#{d}/fish" }.find { |f| File.executable?(f) }
    unless fish
      puts "skipped (fish not installed)"; return
    end
    home, env = sync_home('inshell_fish', ['fish'], %w[go/bin it's])
    write_entries(env: { 'GOPATH' => '$HOME/go' },
                  paths: { 'gobin' => '$GOPATH/bin', 'cargo' => '${NO_SUCH_WAYU_VAR}/bin', 'quote' => "~/it's" },
                  data: "#{home}/.local/share/wayu")
    Open3.capture3(env, @wayu_bin, '--shell', 'fish', 'build')
    out, err, = Open3.capture3(env.merge('PATH' => '/usr/bin'), fish, '--no-config', '-c',
                               "source $HOME/.local/share/wayu/core.fish; string join : $PATH")
    if out.strip.split(':') == ["#{home}/go/bin", "#{home}/it's", '/usr/bin']
      puts "✓"; @passed += 1
    else
      puts "✗"; puts "  PATH=#{out.strip} err=#{err.strip[0, 300]}"; @failed += 1
    end
  end

  # OKAMI-213 (CFG-13): entries.json replaced outside the CLI (a restore
  # by hand, a dotfiles sync) reaches path_sync via `wayu build`, and an open
  # shell at its next prompt even without it (the hook regenerates when
  # entries.json is newer).
  def test_hand_edits_reach_open_shells
    { '/bin/bash' => 'bash', '/bin/zsh' => 'zsh' }.each do |bin, sh|
      print "Test: external entries.json changes reach open shells (#{bin})... "
      home, env = sync_home("hand_#{sh}", [sh], %w[d1 d2 d3 d4])
      Open3.capture3(env, @wayu_bin, '--shell', sh, 'path', 'add', "#{home}/d1")
      store = "#{home}/.local/share/wayu/entries.json"
      snap = lambda do |name, keys|
        file = "#{home}/#{name}.json"
        File.write(file, JSON.generate('version' => 1, 'paths' => keys.map { |k| { 'key' => k, 'dir' => "#{home}/#{k}" } }))
        file
      end
      s2 = snap.call('s2', %w[d1 d2])
      s4 = snap.call('s4', %w[d1 d2 d4])
      script = <<~SH
        . "$HOME/.local/share/wayu/core.#{sh}"
        has() { case ":$PATH:" in *":$HOME/$1:"*) echo y ;; *) echo n ;; esac; }
        sleep 1; cp "$S2" "$STORE"
        "$W" --shell #{sh} build >/dev/null 2>&1; _wayu_paths_sync; echo "build=$(has d2)"
        sleep 1; cp "$S4" "$STORE"
        PATH="$DECOY:$PATH"; _wayu_paths_sync; echo "hook=$(has d4)"
      SH
      # A stale wayu earlier on PATH (e.g. Homebrew while running a dev build)
      # must not be the one the hook runs: it uses _WAYU_BIN, the generator.
      decoy = "#{home}/decoy"
      FileUtils.mkdir_p(decoy)
      File.write("#{decoy}/wayu", "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, "#{decoy}/wayu")
      extra = { 'STORE' => store, 'S2' => s2, 'S4' => s4, 'DECOY' => decoy }
      out, err, = Open3.capture3(env.merge(extra), bin, '-c', script)
      if out.lines.map(&:strip) == %w[build=y hook=y]
        puts "✓"; @passed += 1
      else
        puts "✗"; puts "  out=#{out.lines.map(&:strip).inspect} err=#{err.strip[0, 300]}"; @failed += 1
      end
    end
  end

  # zsh prefers <file>.zwc when it is at least as new as the source (whole
  # seconds), so a digest compiled from old content must not survive a
  # rewrite. A future-dated .zwc makes the race deterministic.
  def test_rewrite_drops_stale_zwc
    print "Test: rewriting core.zsh drops a stale .zwc... "
    home, env = sync_home('stalezwc', ['zsh'])
    cfg = "#{home}/.local/share/wayu"
    Open3.capture3(env, @wayu_bin, '--shell', 'zsh', 'const', 'add', 'ZWC_PROBE_C', 'old')
    Open3.capture3(env, '/bin/zsh', '-fc', "zcompile '#{cfg}/core.zsh' && touch -t 203001010000 '#{cfg}/core.zsh.zwc'")
    Open3.capture3(env, @wayu_bin, '--shell', 'zsh', 'const', 'add', 'ZWC_PROBE_C', 'new')
    out, = Open3.capture3(env, '/bin/zsh', '-fc', ". '#{cfg}/core.zsh' >/dev/null 2>&1; echo \"$ZWC_PROBE_C\"")
    if out.strip == 'new'
      puts "✓"; @passed += 1
    else
      puts "✗"; puts "  ZWC_PROBE_C=#{out.strip} zwc_exists=#{File.exist?("#{cfg}/core.zsh.zwc")}"; @failed += 1
    end
  end

  # OKAMI-221: the native prompt (vi keymap, zle widgets, precmd hooks) is
  # opt-in via `[prompt] enabled = true`. OKAMI-223: [prompt] text and
  # keybindings are literal in generated code — `$(...)` never runs.
  def test_prompt_opt_in_and_escaping
    print "Test: native prompt is opt-in; [prompt]/keybinding values stay literal... "
    home, env = sync_home('prompt_optin', ['zsh'])
    cfg = "#{home}/.config/wayu"
    data = "#{home}/.local/share/wayu"
    pwn = "#{home}/PWNED"
    base = File.exist?("#{cfg}/wayu.toml") ? File.read("#{cfg}/wayu.toml") : ''
    File.write("#{cfg}/wayu.toml", base + "\n[prompt]\nformat = \"{dir} {character}\"\n")
    Open3.capture3(env, @wayu_bin, '--shell', 'zsh', 'const', 'add', 'PROMPT_PROBE_C', '1')
    off_ok = File.exist?("#{data}/core.zsh") && !File.read("#{data}/core.zsh").include?('_wayu_prompt_master')

    File.write("#{cfg}/wayu.toml", base + <<~TOML)

      [prompt]
      enabled = true
      format = 'it"s $(touch #{pwn}) `touch #{pwn}` {character}'

      [prompt.interactive]
      toggle_key = "^X'; touch #{pwn}; '"

      [settings]
      autosuggestions_accept_keys = ["^Y'; touch #{pwn}; '"]
    TOML
    Open3.capture3(env, @wayu_bin, '--shell', 'zsh', 'const', 'add', 'PROMPT_PROBE_C', '2')
    core = File.read("#{data}/core.zsh")
    on_ok = core.include?('_wayu_prompt_master') && !core.include?('.wayu_async_$$')
    files = ["#{data}/core.zsh", "#{data}/plugins/config.zsh"].select { |f| File.exist?(f) }
    syntax_ok = files.size == 2 && files.all? { |f| system('zsh', '-n', f, out: File::NULL, err: File::NULL) }
    keys_ok = files.size == 2 && File.read(files[1]).include?(%q{bindkey '^Y'\''; touch})
    out, = Open3.capture3(env, '/bin/zsh', '-fic',
      "source '#{data}/core.zsh' >/dev/null 2>&1; source '#{data}/plugins/config.zsh' >/dev/null 2>&1; _wayu_prompt_full; print -r -- \"$REPLY\"")
    literal_ok = out.include?("it\"s $(touch #{pwn}) `touch #{pwn}`")
    if off_ok && on_ok && syntax_ok && keys_ok && literal_ok && !File.exist?(pwn)
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  off=#{off_ok} on=#{on_ok} syntax=#{syntax_ok} keys=#{keys_ok} literal=#{literal_ok} pwned=#{File.exist?(pwn)}"
      puts "  out=#{out.inspect}"
      @failed += 1
    end
  end

  # Large stores (thousands of aliases) must not overflow the generator.
  def test_large_toml_regenerates
    print "Test: regenerate with 4000 aliases + [tools] succeeds... "
    home = "#{@tmp_home}/large"
    FileUtils.mkdir_p("#{home}/.config/wayu")
    env = { 'HOME' => home, 'SHELL' => '/bin/zsh' }
    aliases = (1..4000).to_h { |i| ["a#{i}", "echo #{'x' * 120} #{i}"] }
    File.write("#{home}/.config/wayu/wayu.toml",
               "[tools]\nnosuchtoolxyz = { kind = \"evalcache\", args = \"init zsh\" }\n")
    write_entries(aliases: aliases, data: "#{home}/.local/share/wayu")
    _, _, st = Open3.capture3(env, "#{@wayu_bin} build")
    core = "#{home}/.local/share/wayu/core.zsh"
    lazy = core
    if st.success? && File.read(core).include?("alias a4000=") && File.read(lazy).include?('_wayu_evalcache nosuchtoolxyz init zsh')
      puts "✓"; @passed += 1
    else
      puts "✗"; puts "  exit=#{st.exitstatus}"; @failed += 1
    end
  end

  # `build --dry-run` must not write anything.
  def test_build_dry_run_writes_nothing
    print "Test: build --dry-run writes nothing... "
    home = "#{@tmp_home}/dry_eval"
    FileUtils.mkdir_p("#{home}/.config/wayu")
    env = { 'HOME' => home, 'SHELL' => '/bin/zsh' }
    File.write("#{home}/.config/wayu/wayu.toml", "[shell]\ntype = \"zsh\"\n")
    write_entries(aliases: { 'x' => 'y' }, data: "#{home}/.local/share/wayu")
    out, _, st = Open3.capture3(env, "#{@wayu_bin} --dry-run build")
    if st.success? && !File.exist?("#{home}/.local/share/wayu/core.zsh")
      puts "✓"; @passed += 1
    else
      puts "✗"; puts "  core.zsh written under dry-run: #{out}"; @failed += 1
    end
  end

end

# Run tests if executed directly
if __FILE__ == $0
  InitIntegrationTest.new.run
end
