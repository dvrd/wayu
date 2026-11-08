#!/usr/bin/env ruby
# Integration tests for input validation

require 'open3'
require 'fileutils'
require_relative 'test_helper'

class ValidationIntegrationTest
  include WayuTestHelper

  def initialize
    setup_test_env
  end

  def run
    puts "🔒 Testing input validation integration..."
    puts

    begin
      build_project
      initialize_wayu

      test_alias_shell_reserved
      test_alias_dangerous_chars
      test_constant_shell_reserved
      test_constant_lowercase_warning
      test_path_dangerous_chars
      test_path_rejects_separator
      test_alias_valid_input
      test_constant_valid_input
      test_path_valid_input
      test_toml_validate_unknown_keys
    ensure
      teardown_test_env
    end

    print_summary("validation")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def test_alias_shell_reserved
    print "Test 1: Reject shell reserved word in alias... "
    output, status = run_wayu('alias add if "echo test"')

    if output.include?("reserved shell keyword") || output.include?("reserved word")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected reserved word error"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_alias_dangerous_chars
    print "Test 2: Reject dangerous characters in alias... "
    output, status = run_wayu('alias add "my;alias" "echo test"')

    if output.include?("contains invalid character") || output.include?("Invalid")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected invalid character error"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_constant_shell_reserved
    print "Test 3: Reject shell reserved word in constant... "
    output, status = run_wayu('constants add while "value"')

    if output.include?("reserved shell keyword") || output.include?("reserved word")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected reserved word error"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_constant_lowercase_warning
    print "Test 4: Warn about lowercase in constants... "
    output, status = run_wayu('constants add my_var "value"')

    if output.include?("lowercase") || output.include?("UPPER_CASE") || output.include?("Warning")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected lowercase warning"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  # OKAMI-214: ':' splits into extra (even relative '.') PATH entries; a
  # newline breaks generated files. Both must be rejected by `path add`, and
  # a hand-edited [paths] value with ':' must never reach PATH.
  def test_path_rejects_separator
    print "Test: Reject ':' and newline in PATH entries (CLI + hand-edited TOML)... "
    colon = "#{@tmp_home}/co:lon"
    dot = "#{@tmp_home}/a:."
    nl = "#{@tmp_home}/new\nline"
    [colon, dot, nl].each { |d| FileUtils.mkdir_p(d) }
    env = ENV.to_h.merge('HOME' => @tmp_home)
    codes = [colon, dot, nl].map { |d| Open3.capture3(env, @wayu_bin, '--shell', 'zsh', 'path', 'add', d)[2].exitstatus }
    toml_file = "#{@config_dir}/wayu.toml"
    toml = File.read(toml_file)
    stored = toml.include?('co:lon') || toml.include?('a:.')
    toml = toml.include?('[paths]') ? toml.sub('[paths]', "[paths]\nhand = \"#{dot}\"") : toml + "\n[paths]\nhand = \"#{dot}\"\n"
    File.write(toml_file, toml)
    Open3.capture3(env, @wayu_bin, '--shell', 'zsh', 'build', 'eval')
    sync = File.exist?("#{@data_dir}/path_sync.zsh") ? File.read("#{@data_dir}/path_sync.zsh") : ''
    out, = Open3.capture3(env, 'zsh', '-fc', ". '#{@data_dir}/core.zsh' >/dev/null 2>&1; print -rl -- $path")
    bad_entry = out.lines.map(&:chomp).any? { |l| ['.', "#{@tmp_home}/a", "#{@tmp_home}/co"].include?(l) }
    if codes.all? { |c| c == 65 } && !stored && !sync.include?('a:.') && !bad_entry
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  codes=#{codes} stored=#{stored} sync_has=#{sync.include?('a:.')} bad_entry=#{bad_entry}"
      @failed += 1
    end
  end

  # Keys wayu does not read are warnings (exit 0); a table in the wrong
  # shape ([[paths]], the 3.x schema) is an error (exit 65), no migration hint.
  def test_toml_validate_unknown_keys
    print "Test: toml validate warns on unknown keys, rejects [[paths]]... "
    toml_file = "#{@config_dir}/wayu.toml"
    before = File.read(toml_file)
    File.write(toml_file, "[shell]\ntype = \"zsh\"\n\n[settings]\nauto_backup = true\n\n[constants]\nX = \"1\"\n")
    warn_out, warn_st = run_wayu('toml validate')
    File.write(toml_file, "[[paths]]\npath = \"/usr/bin\"\n")
    err_out, err_st = run_wayu('toml validate')
    File.write(toml_file, before)
    ok = warn_st.exitstatus == 0 && warn_out.include?('line 5: unknown key settings.auto_backup') &&
         warn_out.include?('line 7: unknown table [constants]') &&
         err_st.exitstatus == 65 && err_out.include?('paths must be a table') && !err_out.include?('migrate')
    if ok
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  warn exit=#{warn_st.exitstatus} out=#{warn_out.strip}"
      puts "  err exit=#{err_st.exitstatus} out=#{err_out.strip}"
      @failed += 1
    end
  end

  def test_path_dangerous_chars
    print "Test 5: Sanitize dangerous characters in path... "

    # Create a test directory with spaces
    test_dir = "#{@scratch}/test dir"
    Dir.mkdir(test_dir)

    begin
      output, status = run_wayu("path add \"#{test_dir}\"")

      # Check if it was added (should handle spaces properly)
      if status.success? || output.include?("Added")
        puts "✓"
        @passed += 1
      else
        puts "✗"
        puts "  Failed to add path with spaces"
        puts "  Output: #{output}"
        @failed += 1
      end
    ensure
      FileUtils.rm_rf(test_dir) if Dir.exist?(test_dir)
    end
  end

  def test_alias_valid_input
    print "Test 6: Accept valid alias... "
    output, status = run_wayu('alias add myalias "echo hello"')

    if status.success? && (output.include?("added successfully") || output.include?("Added to wayu.toml"))
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to add valid alias"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_constant_valid_input
    print "Test 7: Accept valid constant... "
    output, status = run_wayu('constants add MY_CONSTANT "value123"')

    if status.success? && (output.include?("added successfully") || output.include?("Added to wayu.toml"))
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to add valid constant"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_path_valid_input
    print "Test 8: Accept valid path... "
    output, status = run_wayu('path add /usr/local/bin')

    if status.success? && (output.include?("added successfully") || output.include?("Added to wayu.toml"))
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to add valid path"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

end

# Run tests if executed directly
if __FILE__ == $0
  ValidationIntegrationTest.new.run
end
