#!/usr/bin/env ruby
# Integration tests for the `wayu function` command

require 'open3'
require 'fileutils'
require_relative 'test_helper'

class FunctionIntegrationTest
  include WayuTestHelper

  def initialize
    setup_test_env
  end

  def run
    puts "🔧 Testing function command integration..."
    puts

    begin
      build_project
      initialize_wayu(shell: 'zsh')

      test_list_empty
      test_add_creates_file_in_config_dir
      test_list_shows_added_function
      test_remove_requires_yes
      test_remove_with_yes
      test_remove_missing_function
      test_add_rejects_invalid_name
      test_fn_alias
      test_function_loads_in_real_shell
    ensure
      teardown_test_env
    end

    print_summary("function")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  # Run wayu with HOME override plus a non-interactive EDITOR so `function add`
  # never blocks on a real editor.
  def run_wayu_func(args)
    env = ENV.to_h.merge('HOME' => @tmp_home, 'EDITOR' => '/usr/bin/true')
    project_root = File.expand_path('../..', __dir__)
    stdout, stderr, status = Open3.capture3(env, "#{@wayu_bin} #{args}", chdir: project_root)
    [(stdout + stderr).force_encoding('UTF-8'), status]
  end

  def functions_dir
    "#{@config_dir}/functions"
  end

  def check(label, condition, detail = nil)
    print "#{label}... "
    if condition
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  #{detail}" if detail
      @failed += 1
    end
  end

  def test_list_empty
    output, status = run_wayu_func("function list")
    check("Test 1: List with no functions",
          status.success? && output.include?("No functions"),
          "Output: #{output}")
  end

  def test_add_creates_file_in_config_dir
    output, status = run_wayu_func("function add greet")
    file = "#{functions_dir}/greet.zsh"
    check("Test 2: Add creates a function file in the config dir",
          status.success? && File.exist?(file),
          "Expected #{file}; Output: #{output}")
  end

  def test_list_shows_added_function
    output, status = run_wayu_func("function list")
    check("Test 3: List shows the added function",
          status.success? && output.include?("greet"),
          "Output: #{output}")
  end

  def test_remove_requires_yes
    output, status = run_wayu_func("function remove greet")
    # EXIT_USAGE = 64; file must still exist.
    check("Test 4: Remove without --yes is blocked",
          status.exitstatus == 64 && File.exist?("#{functions_dir}/greet.zsh"),
          "Exit: #{status.exitstatus}; Output: #{output}")
  end

  def test_remove_with_yes
    output, status = run_wayu_func("function remove greet --yes")
    check("Test 5: Remove with --yes deletes the function",
          status.success? && !File.exist?("#{functions_dir}/greet.zsh"),
          "Output: #{output}")
  end

  def test_remove_missing_function
    output, status = run_wayu_func("function remove does_not_exist --yes")
    # EXIT_NOINPUT = 66
    check("Test 6: Remove of a missing function fails cleanly",
          status.exitstatus == 66 && output.include?("not found"),
          "Exit: #{status.exitstatus}; Output: #{output}")
  end

  def test_add_rejects_invalid_name
    output, status = run_wayu_func("function add 'bad name'")
    # EXIT_DATAERR = 65
    check("Test 7: Add rejects an invalid function name",
          status.exitstatus == 65 && output.downcase.include?("invalid"),
          "Exit: #{status.exitstatus}; Output: #{output}")
  end

  def test_fn_alias
    run_wayu_func("function add helper")
    output, status = run_wayu_func("fn list")
    check("Test 8: `fn` alias resolves to the function command",
          status.success? && output.include?("helper"),
          "Output: #{output}")
  end

  # End-to-end: a function created via `wayu function add` must actually be
  # callable after sourcing the generated init script in a real zsh. This is
  # the flow a user experiences; it catches init-orchestration / glob-syntax
  # regressions that file-content assertions miss.
  def test_function_loads_in_real_shell
    label = "Test 9: Function callable after sourcing init.zsh in real zsh"
    unless system("command -v zsh > /dev/null 2>&1")
      print "#{label}... "
      puts "⊘ (zsh unavailable, skipped)"
      return
    end

    File.write("#{functions_dir}/wayu_e2e_marker.zsh", "wayu_e2e_marker() { echo E2E_MARKER_OK; }\n")
    init = "#{@data_dir}/init.zsh"
    script = %(source "#{init}" >/dev/null 2>&1; ) +
             %(if typeset -f wayu_e2e_marker >/dev/null; then wayu_e2e_marker; else echo NOT_LOADED; fi)
    out, _ = Open3.capture2e({ 'HOME' => @tmp_home }, 'zsh', '-c', script)
    check(label, out.include?("E2E_MARKER_OK"), "Output: #{out}")
  end
end

# Run tests if executed directly
if __FILE__ == $0
  FunctionIntegrationTest.new.run
end
