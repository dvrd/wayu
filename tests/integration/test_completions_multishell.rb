#!/usr/bin/env ruby
# Integration tests asserting `wayu completions add` honors the active
# shell's filename convention (zsh '_name', bash 'name.bash-completion',
# fish 'name.fish'). The legacy test_completions.rb only covers zsh; this
# file covers the shell-aware branch introduced in v3.11.0.

require 'fileutils'
require 'open3'
require_relative 'test_helper'

class CompletionsMultishellTest
  include WayuTestHelper

  def initialize
    setup_test_env
  end

  def run
    puts "📋 Testing multishell completions integration..."
    puts
    begin
      build_project
      test_bash_uses_bash_completion_suffix
      test_fish_uses_fish_suffix
      test_prencoded_name_is_respected
      test_remove_works_regardless_of_shell_convention
    ensure
      teardown_test_env
    end
    print_summary("completions-multishell")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  # Override of the helper's run_wayu that lets us pin SHELL per-invocation.
  def run_with_shell(shell_path, args)
    env = ENV.to_h.merge('HOME' => @tmp_home, 'SHELL' => shell_path)
    project_root = File.expand_path('../..', __dir__)
    stdout, stderr, status = Open3.capture3(env, "#{@wayu_bin} #{args}", chdir: project_root)
    [stdout.force_encoding('UTF-8') + stderr.force_encoding('UTF-8'), status]
  end

  def init_for(shell_flag)
    out, status = run_with_shell(shell_default_for(shell_flag), "init --shell #{shell_flag}")
    unless status.success?
      puts "  init failed (shell=#{shell_flag}): #{out}"
      return false
    end
    true
  end

  # Pick a $SHELL value that makes wayu's shell detection resolve to the
  # expected ShellType even when the binary isn't installed locally.
  def shell_default_for(flag)
    case flag
    when 'bash' then '/bin/bash'
    when 'fish' then '/usr/bin/fish'
    when 'zsh'  then '/bin/zsh'
    end
  end

  def test_bash_uses_bash_completion_suffix
    print "Test 1: bash completions add => name.bash-completion... "
    # Fresh HOME per test to keep filenames deterministic.
    FileUtils.rm_rf("#{@tmp_home}/.config")
    FileUtils.mkdir_p("#{@tmp_home}/.config")
    return puts("✗ init failed") unless init_for('bash')

    src = "#{@config_dir}/_src_jj.sh"
    File.write(src, "# dummy bash completion for jj\n")

    _, status = run_with_shell('/bin/bash', "--shell bash completions add jj #{src}")
    expected = "#{@config_dir}/completions/jj.bash-completion"
    zsh_leak = "#{@config_dir}/completions/_jj"

    if status.success? && File.exist?(expected) && !File.exist?(zsh_leak)
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  exit_ok=#{status.success?} target_exists=#{File.exist?(expected)} zsh_leaked=#{File.exist?(zsh_leak)}"
      @failed += 1
    end
  end

  def test_fish_uses_fish_suffix
    print "Test 2: fish completions add => name.fish... "
    FileUtils.rm_rf("#{@tmp_home}/.config")
    FileUtils.mkdir_p("#{@tmp_home}/.config")
    return puts("✗ init failed") unless init_for('fish')

    src = "#{@config_dir}/_src.fish"
    File.write(src, "# dummy fish completion\ncomplete -c jj -s h\n")

    _, status = run_with_shell('/usr/bin/fish', "--shell fish completions add jj #{src}")
    expected = "#{@config_dir}/completions/jj.fish"
    if status.success? && File.exist?(expected)
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  exit_ok=#{status.success?} target_exists=#{File.exist?(expected)}"
      @failed += 1
    end
  end

  def test_prencoded_name_is_respected
    print "Test 3: explicit suffix in name is kept regardless of shell... "
    FileUtils.rm_rf("#{@tmp_home}/.config")
    FileUtils.mkdir_p("#{@tmp_home}/.config")
    return puts("✗ init failed") unless init_for('zsh')

    src = "#{@config_dir}/src.fish"
    File.write(src, "# completion ported as-is\n")

    # User passes 'foo.fish' under zsh — wayu should not rename it to _foo.fish.
    _, status = run_with_shell('/bin/zsh', "--shell zsh completions add foo.fish #{src}")
    expected = "#{@config_dir}/completions/foo.fish"
    zsh_leak = "#{@config_dir}/completions/_foo.fish"
    if status.success? && File.exist?(expected) && !File.exist?(zsh_leak)
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  exit_ok=#{status.success?} expected=#{File.exist?(expected)} rename_leak=#{File.exist?(zsh_leak)}"
      @failed += 1
    end
  end

  def test_remove_works_regardless_of_shell_convention
    print "Test 4: completions rm scans every convention... "
    FileUtils.rm_rf("#{@tmp_home}/.config")
    FileUtils.mkdir_p("#{@tmp_home}/.config")
    return puts("✗ init failed") unless init_for('zsh')

    # Manually drop a fish-style completion into the dir, then try to remove
    # using only the bare name under zsh. find_existing_completion should
    # find foo.fish even though zsh convention would look for _foo first.
    File.write("#{@config_dir}/completions/foo.fish", "# manually installed\n")
    _, status = run_with_shell('/bin/zsh', "--shell zsh completions remove foo")

    if status.success? && !File.exist?("#{@config_dir}/completions/foo.fish")
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  exit_ok=#{status.success?} file_removed=#{!File.exist?("#{@config_dir}/completions/foo.fish")}"
      @failed += 1
    end
  end
end

CompletionsMultishellTest.new.run if __FILE__ == $0
