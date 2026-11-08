#!/usr/bin/env ruby
# Integration tests exercising the fish-specific code paths.
# Overrides SHELL=fish so wayu's DETECTED_SHELL resolves to .FISH.

require 'open3'
require 'fileutils'
require_relative 'test_helper'

class FishIntegrationTest
  include WayuTestHelper

  def initialize
    setup_test_env
    @toml_file = "#{@config_dir}/wayu.toml"
    @init_core = "#{@data_dir}/core.fish"
  end

  def run
    puts "🐟 Testing fish shell integration..."
    puts

    begin
      build_project
      initialize_fish

      test_toml_shell_type_is_fish
      test_alias_writes_to_toml
      test_constant_writes_to_toml
      test_path_writes_to_toml
      test_init_core_fish_is_native_syntax
      test_watch_regenerate_emits_fish
      test_completion_add_uses_fish_naming
      test_template_applies_to_toml_with_fish_syntax
      test_mutations_auto_regenerate_init_core
      test_init_fish_prefers_init_core
      test_fish_escaping
      test_all_generated_fish_files_parse
      test_fish_parity_tools_functions_path_sync
    ensure
      teardown_test_env
    end

    print_summary("fish")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  # Override initialize_wayu from helper so we can force SHELL=fish.
  def initialize_fish
    print "Initializing wayu config for fish..."
    output, status = run_fish('init --shell fish')
    if status.success?
      puts " ✓"
    else
      puts " ✗"
      puts "Init failed: #{output}"
      teardown_test_env
      exit 1
    end
    puts
  end

  # Like run_wayu but forces SHELL=/usr/bin/fish so DETECTED_SHELL is FISH.
  def run_fish(args)
    env = ENV.to_h.merge('HOME' => @tmp_home, 'SHELL' => '/usr/bin/fish')
    project_root = File.expand_path('../..', __dir__)
    stdout, stderr, status = Open3.capture3(env, "#{@wayu_bin} #{args}", chdir: project_root)
    [stdout.force_encoding('UTF-8') + stderr.force_encoding('UTF-8'), status]
  end

  def test_toml_shell_type_is_fish
    print "Test 1: wayu.toml records type=\"fish\"... "
    content = File.read(@toml_file)
    if content.include?(%q{type = "fish"})
      puts "✓"; @passed += 1
    else
      puts "✗"; puts "  TOML did not record Fish shell type"
      puts "  Content: #{content[0..200]}"; @failed += 1
    end
  end

  def test_alias_writes_to_toml
    print "Test 2: alias add writes to entries.json (fish)... "
    _, status = run_fish('alias add ll "ls -la"')
    if status.success? && store_map('aliases')['ll'] == 'ls -la'
      puts "✓"; @passed += 1
    else
      puts "✗"; puts "  Alias not written to entries.json under fish"; @failed += 1
    end
  end

  def test_constant_writes_to_toml
    print "Test 3: constants add writes to entries.json (fish)... "
    _, status = run_fish('constants add API_URL "https://example.com"')
    if status.success? && store_map('env')['API_URL'] == 'https://example.com'
      puts "✓"; @passed += 1
    else
      puts "✗"; puts "  Constant not written to entries.json under fish"; @failed += 1
    end
  end

  def test_path_writes_to_toml
    print "Test 4: path add writes to entries.json (fish)... "
    _, status = run_fish('path add /tmp')
    if status.success? && store_map('paths').value?('/tmp')
      puts "✓"; @passed += 1
    else
      puts "✗"; puts "  Path not written to entries.json under fish"; @failed += 1
    end
  end

  def test_init_core_fish_is_native_syntax
    print "Test 5: core.fish uses fish-native syntax... "
    # Rebuild after alias/path were added so core.fish reflects them.
    run_fish('build')
    unless File.exist?(@init_core)
      puts "✗"; puts "  core.fish not created"; @failed += 1
      return
    end
    body = File.read(@init_core)
    fish_ok = body.include?('#!/usr/bin/env fish') &&
              body.include?('set -gx PATH') &&
              body.include?("alias ll 'ls -la'")
    bash_leak = body.include?('export PATH=') || body.include?('typeset -U') ||
                body.include?('zsh-defer') || body.include?('autoload')
    if fish_ok && !bash_leak
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  fish_ok=#{fish_ok} bash_leak=#{bash_leak}"
      @failed += 1
    end
  end

  def test_template_applies_to_toml_with_fish_syntax
    print "Test 8: template apply writes to entries.json + fish-native init... "
    # Use a dedicated tmp home so previous tests don't influence content.
    scratch = "#{@tmp_home}/scratch_tpl"
    FileUtils.mkdir_p("#{scratch}/.config")
    # A template never overrides a constant already set in the environment:
    # unset the ones it adds (nil unsets in an Open3 env hash).
    env = ENV.to_h.merge('HOME' => scratch, 'SHELL' => '/usr/bin/fish', 'EDITOR' => nil, 'GOPATH' => nil)
    Open3.capture3(env, "#{@wayu_bin} init --shell fish")
    Open3.capture3(env, "#{@wayu_bin} template apply developer")
    Open3.capture3(env, "#{@wayu_bin} build")
    store = File.read("#{scratch}/.local/share/wayu/entries.json")
    init = File.read("#{scratch}/.local/share/wayu/core.fish")
    toml_ok = store.include?('{"name": "g", "value": "git"}') && store.include?('{"name": "EDITOR", "value": "code --wait"}') &&
              store.include?('"dir": "/opt/homebrew/bin"')
    fish_native = init.include?("alias g 'git'") && init.include?('set -gx EDITOR') &&
                  init.include?('set -gx PATH')
    bash_leak  = init.include?('alias g="git"') || init.include?('export EDITOR=')
    if toml_ok && fish_native && !bash_leak
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  toml_ok=#{toml_ok} fish_native=#{fish_native} bash_leak=#{bash_leak}"
      @failed += 1
    end
  ensure
    FileUtils.rm_rf(scratch) if scratch && Dir.exist?(scratch)
  end

  def test_completion_add_uses_fish_naming
    print "Test 7: completions add uses fish naming (foo.fish)... "
    src = "#{@config_dir}/src_completion.fish"
    File.write(src, "# dummy fish completion\ncomplete -c foo -s h\n")
    _, status = run_fish("completions add foo #{src}")
    target = "#{@data_dir}/completions/foo.fish"
    zsh_target = "#{@data_dir}/completions/_foo"
    if status.success? && File.exist?(target) && !File.exist?(zsh_target)
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  exit=#{status.success?} target_exists=#{File.exist?(target)} zsh_leaked=#{File.exist?(zsh_target)}"
      @failed += 1
    end
  ensure
    File.delete(src) if src && File.exist?(src)
  end

  def test_mutations_auto_regenerate_init_core
    print "Test 9: alias/const/path add auto-regenerate core.fish... "
    scratch = "#{@tmp_home}/scratch_auto"
    FileUtils.mkdir_p("#{scratch}/.config")
    env = ENV.to_h.merge('HOME' => scratch, 'SHELL' => '/usr/bin/fish')
    Open3.capture3(env, "#{@wayu_bin} init --shell fish")
    core = "#{scratch}/.local/share/wayu/core.fish"
    # After fresh init, core.fish is generated but empty of user config.
    baseline_has_alias = File.exist?(core) && File.read(core).include?("alias gg")
    Open3.capture3(env, "#{@wayu_bin} alias add gg 'git status'")
    Open3.capture3(env, "#{@wayu_bin} constants add MY_VAR xyz")
    # No explicit 'build' run — core must reflect changes already.
    body = File.exist?(core) ? File.read(core) : ''
    ok = !baseline_has_alias &&
         body.include?("alias gg 'git status'") &&
         body.include?('set -gx MY_VAR "xyz"')
    if ok
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  baseline_has_alias=#{baseline_has_alias} body_has_alias=#{body.include?('alias gg')} body_has_const=#{body.include?('MY_VAR')}"
      @failed += 1
    end
  ensure
    FileUtils.rm_rf(scratch) if scratch && Dir.exist?(scratch)
  end

  def test_init_fish_prefers_init_core
    print "Test 10: init.fish fast-paths through core.fish... "
    body = File.read(@init_core.sub('core.fish', 'init.fish'))
    if body.include?('if test -f "$WAYU_DATA_DIR/core.fish"') &&
       body.include?('source "$WAYU_DATA_DIR/core.fish"')
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  init.fish did not source core.fish on fast path"
      @failed += 1
    end
  end

  # `wayu watch regenerate` (hot reload) must rewrite core.fish — the file
  # init.fish actually sources — instead of an orphaned wayu_static.fish.
  def test_watch_regenerate_emits_fish
    print "Test 6: watch regenerate rewrites core.fish... "
    File.delete(@init_core) if File.exist?(@init_core)
    _, status = run_fish('watch regenerate')
    unless status.success? && File.exist?(@init_core)
      puts "✗"; puts "  regenerate failed or core.fish missing"; @failed += 1
      return
    end
    body = File.read(@init_core)
    fish_ok = body.include?('#!/usr/bin/env fish') &&
              body.include?('set -gx PATH') &&
              body.include?("alias ll 'ls -la'")
    bash_leak = body.include?('export PATH=') || body.include?('typeset -U')
    no_orphan = !File.exist?("#{@data_dir}/wayu_static.fish")
    if fish_ok && !bash_leak && no_orphan
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  fish_ok=#{fish_ok} bash_leak=#{bash_leak} no_orphan=#{no_orphan}"
      @failed += 1
    end
  end

  # Fish escaping: single-quoted alias bodies escape \ and ', env values stay
  # double-quoted (so $VAR expands) with " and \ escaped. Validated with
  # `fish -n` when fish is installed.
  def test_fish_escaping
    print "Test 11: core.fish escapes quotes/backslashes... "
    write_entries(paths: store_map('paths'),
                  aliases: store_map('aliases').merge('sq' => "echo 'it' a\\b"),
                  env: store_map('env').merge('FQ' => 'say "hi" $HOME'))
    run_fish('build')
    body = File.read(@init_core)
    alias_ok = body.include?(%q{alias sq 'echo \'it\' a\\\\b'})
    env_ok = body.include?(%q{set -gx FQ "say \"hi\" $HOME"})
    syntax_ok = true
    if system('command -v fish >/dev/null 2>&1')
      _, _, st = Open3.capture3('fish', '-n', @init_core)
      syntax_ok = st.success?
    end
    if alias_ok && env_ok && syntax_ok
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  alias_ok=#{alias_ok} env_ok=#{env_ok} syntax_ok=#{syntax_ok}"
      puts body.lines.grep(/sq|FQ/).join
      @failed += 1
    end
  end
  # Every generated *.fish file must parse, and init.fish must source cleanly
  # in a real fish (values from earlier tests include quotes and $HOME).
  def test_all_generated_fish_files_parse
    print "Test 12: every generated .fish file passes fish -n and sources... "
    unless system('command -v fish >/dev/null 2>&1')
      puts "SKIP (fish not installed)"
      return
    end
    files = Dir.glob("#{@config_dir}/**/*.fish") + Dir.glob("#{@data_dir}/**/*.fish")
    bad = files.reject { |f| Open3.capture3('fish', '-n', f)[2].success? }
    env = ENV.to_h.merge('HOME' => @tmp_home)
    _, err, st = Open3.capture3(env, 'fish', '-c', "source #{@data_dir}/init.fish")
    if !files.empty? && bad.empty? && st.success? && err.strip.empty?
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  files=#{files.size} bad=#{bad} source_ok=#{st.success?} stderr=#{err.strip[0, 300]}"
      @failed += 1
    end
  end

  # OKAMI-268: fish gets what zsh/bash get — [tools] (`<tool> init fish |
  # source`, cached), functions/, tools.fish before extra.fish, [paths] moved
  # to the front in order (fish_add_path -gpm), live PATH sync at the next
  # prompt, and no duplicate fish_complete_path entry on re-source.
  def test_fish_parity_tools_functions_path_sync
    print "Test 13: fish [tools], functions/, PATH order + live sync, re-source... "
    fish = ENV['PATH'].split(':').map { |d| "#{d}/fish" }.find { |f| File.executable?(f) }
    unless fish
      puts "SKIP (fish not installed)"
      return
    end
    home = Dir.mktmpdir('wayu_fish_parity')
    begin
      fb = "#{home}/fb"
      %w[fb p1 p2 p3].each { |d| FileUtils.mkdir_p("#{home}/#{d}") }
      File.write("#{fb}/faketool", "#!/bin/sh\necho \"set -g FAKE_ARGS '$*'\"\n")
      File.chmod(0o755, "#{fb}/faketool")
      env = { 'HOME' => home, 'SHELL' => '/usr/bin/fish', 'XDG_CACHE_HOME' => nil,
              'PATH' => "#{fb}:/usr/bin:/bin:/usr/sbin:/sbin" }
      Open3.capture3(env, @wayu_bin, 'init', '--shell', 'fish')
      cfg = "#{home}/.config/wayu"
      data = "#{home}/.local/share/wayu"
      File.open("#{cfg}/wayu.toml", 'a') do |f|
        f.puts "\n[tools]\nfaketool = { args = \"init zsh\" }"
      end
      File.write("#{data}/entries.json", JSON.generate(
        'version' => 1,
        'paths' => [{ 'key' => 'p1', 'dir' => "#{home}/p1" }, { 'key' => 'p2', 'dir' => '$HOME/p2' },
                    { 'key' => 'sys', 'dir' => '/bin' }]
      ))
      FileUtils.mkdir_p("#{cfg}/functions")
      File.write("#{cfg}/functions/myfn.fish", "function myfn; echo myfn; end\n")
      File.write("#{cfg}/tools.fish", "set -g ORDER tools\n")
      File.write("#{cfg}/extra.fish", "set -a ORDER extra\n")
      _, berr, bst = Open3.capture3(env, @wayu_bin, 'build')
      script = <<~FISH
        source #{data}/init.fish
        source #{data}/init.fish
        echo "path=$PATH[1..3]"
        echo "args=$FAKE_ARGS"
        functions -q myfn; and echo myfn-ok
        echo "order=$ORDER[-2..-1]"
        echo "compl="(count (string match -- '*/wayu/completions' $fish_complete_path))
        #{@wayu_bin} path add #{home}/p3 >/dev/null 2>&1
        emit fish_prompt
        echo "synced="(contains -i -- #{home}/p3 $PATH)
      FISH
      out, err, st = Open3.capture3(env, fish, '--no-config', '-c', script)
      cache = Dir.glob("#{home}/.cache/wayu/evalcache/fish__faketool*")
      ok = bst.success? && st.success? && err.strip.empty? &&
           out.include?("path=#{home}/p1:#{home}/p2:/bin\n") &&
           out.include?("args=init fish\n") && out.include?("myfn-ok\n") &&
           out.include?("order=tools extra\n") && out.include?("compl=1\n") &&
           out.include?("synced=4\n") && cache.size == 1
      if ok
        puts "✓"; @passed += 1
      else
        puts "✗"
        puts "  build=#{bst.success?} #{berr.strip[0, 200]} cache=#{cache}"
        puts "  out=#{out} err=#{err.strip[0, 300]}"
        @failed += 1
      end
    ensure
      FileUtils.rm_rf(home)
    end
  end
end

FishIntegrationTest.new.run if __FILE__ == $0
