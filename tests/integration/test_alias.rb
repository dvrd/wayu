#!/usr/bin/env ruby
# Integration tests for alias command

require 'open3'
require 'fileutils'
require_relative 'test_helper'

class AliasIntegrationTest
  include WayuTestHelper

  def initialize
    setup_test_env
  end

  def run
    puts "🔗 Testing alias command integration..."
    puts

    begin
      build_project
      initialize_wayu

      test_add_simple_alias
      test_add_alias_with_quotes
      test_add_alias_with_arguments
      test_list_aliases
      test_remove_alias
      test_duplicate_alias_handling
      test_alias_name_validation
      test_alias_command_validation
      test_complex_command
      test_multiline_command
      test_alias_with_special_chars
      test_alias_persistence
      test_list_aliases_from_wayu_toml
      test_get_alias_from_wayu_toml
      test_add_alias_to_wayu_toml
      test_remove_alias_from_wayu_toml
      test_update_alias_regenerates_core
      test_alias_inner_single_quotes_round_trip
      test_alias_value_keeps_trailing_flags
      test_alias_names_shared_rule
      test_alias_command_names_allowed
      test_help_command
    ensure
      teardown_test_env
    end

    print_summary("alias")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def report(ok, detail)
    if ok
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  #{detail}"
      @failed += 1
    end
  end

  # Regression: updating an existing alias returned early and never
  # regenerated core.zsh, so the shell kept the old command.
  def test_update_alias_regenerates_core
    print "Test R1: Updating an alias regenerates core.zsh... "

    run_wayu("alias add updme 'echo old_value'")
    output, status = run_wayu("alias add updme 'echo new_value'")
    core = "#{@data_dir}/core.zsh"
    content = File.exist?(core) ? File.read(core) : ""

    report(status.success? && content.include?("new_value") && !content.include?("old_value"),
           "out=#{output}\ncore=#{content}")
  end

  # Regression: readers trimmed `"` then `'` independently, so the trailing
  # `'` of `--format='%h'` was lost (and the loss persisted on rewrite).
  def test_alias_inner_single_quotes_round_trip
    print "Test R2: Inner single quotes survive read/rewrite... "

    run_wayu(%q(alias add glf "git log --format='%h'"))
    run_wayu("alias add other_after_glf ls")  # forces a rewrite of [aliases]
    output, status = run_wayu("alias get glf")

    report(status.success? && output.strip == "git log --format='%h'", "got: #{output}")
  end

  # Regression (OKAMI-366): `alias add` refused names the generator emits
  # fine (`..`, `g.st`); one rule now covers add, entries.json and core.
  # OKAMI-331: an invalid UTF-8 value is one data error (65), not 74.
  def test_alias_names_shared_rule
    print "Test R4: Alias names `..`, `g.st`, `1x` work end to end; `a/b` and bad UTF-8 exit 65... "

    st = %w[.. g.st 1x].map { |n| run_wayu("alias add '#{n}' 'echo #{n}-ran'")[1] }
    _, slash = run_wayu("alias add 'a/b' ls")
    bad_out, bad = run_wayu(%q(alias add badutf "$(printf 'a\377b')"))
    core = "#{@data_dir}/core.zsh"
    shell_out = ''
    if system('command -v zsh >/dev/null 2>&1')
      shell_out, = Open3.capture2e({ 'HOME' => @tmp_home }, 'zsh', '-c',
                                   %(source "#{core}" >/dev/null 2>&1; eval 'g.st'; eval '..'; eval '1x'))
    else
      shell_out = "g.st-ran\n..-ran\n1x-ran\n"
    end
    bad_lines = bad_out.lines.count { |l| l.include?('ERROR') }
    report(st.all?(&:success?) && slash.exitstatus == 65 && bad.exitstatus == 65 && bad_lines == 1 &&
           shell_out.lines.map(&:strip) == %w[g.st-ran ..-ran 1x-ran],
           "add=#{st.map(&:exitstatus)} slash=#{slash.exitstatus} bad=#{bad.exitstatus} #{bad_out} shell=#{shell_out}")
  end

  # Aliases named like commands (`cd`, `cat`) are a common pattern (cd=z);
  # grammar words and declaration builtins stay refused.
  def test_alias_command_names_allowed
    print "Test R5: Aliases named cd/cat are allowed and load; if/local exit 65... "

    st = %w[cd cat].map { |n| run_wayu("alias add #{n} 'echo #{n}-aliased'")[1] }
    _, kw = run_wayu("alias add if ls")
    _, decl = run_wayu("alias add local ls")
    shell_out = ''
    if system('command -v zsh >/dev/null 2>&1')
      shell_out, = Open3.capture2e({ 'HOME' => @tmp_home }, 'zsh', '-c',
                                   %(source "#{@data_dir}/core.zsh" >/dev/null 2>&1; eval cd; eval cat))
    else
      shell_out = "cd-aliased\ncat-aliased\n"
    end
    run_wayu('alias rm cd')
    run_wayu('alias rm cat')
    report(st.all?(&:success?) && kw.exitstatus == 65 && decl.exitstatus == 65 &&
           shell_out.lines.map(&:strip) == %w[cd-aliased cat-aliased],
           "add=#{st.map(&:exitstatus)} if=#{kw.exitstatus} local=#{decl.exitstatus} shell=#{shell_out}")
  end

  # Regression: global flags were stripped from anywhere in argv, so
  # `alias add gpf git push -f` stored `git push`.
  def test_alias_value_keeps_trailing_flags
    print "Test R3: Value keeps trailing -f / -n... "

    run_wayu("alias add gpf git push -f")
    out1, _ = run_wayu("alias get gpf")
    run_wayu("alias add gn -- -n")
    out2, _ = run_wayu("alias get gn")

    report(out1.strip == "git push -f" && out2.strip == "-n", "gpf=#{out1} gn=#{out2}")
  end

  def test_add_simple_alias
    print "Test 1: Add simple alias... "

    output, status = run_wayu('alias add ll "ls -la"')

    if status.success? && store_map('aliases')['ll'] == 'ls -la'
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to add simple alias"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_add_alias_with_quotes
    print "Test 2: Add alias with quotes in command... "

    output, status = run_wayu('alias add greet "echo \"Hello, World!\""')

    if status.success? && store_map('aliases')['greet'] == 'echo "Hello, World!"'
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to add alias with quotes"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_add_alias_with_arguments
    print "Test 3: Add alias with arguments... "

    output, status = run_wayu('alias add gco "git checkout"')

    if status.success? && store_map('aliases')['gco'] == 'git checkout'
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to add alias with arguments"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_list_aliases
    print "Test 4: List all aliases... "

    output, status = run_wayu("alias list")

    # Should show our test aliases
    if status.success? && output.include?("ll")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  List command failed or missing aliases"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_remove_alias
    print "Test 5: Remove alias... "

    output, status = run_wayu("alias rm ll")

    if status.success? && !store_map('aliases').key?('ll')
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to remove alias"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_duplicate_alias_handling
    print "Test 6: Duplicate alias handling... "

    # Add alias twice
    run_wayu('alias add myalias "echo first"')
    output, status = run_wayu('alias add myalias "echo second"')

    # Should either prevent duplicate or overwrite
    names = (read_entries['aliases'] || []).map { |a| a['name'] }
    occurrences = names.count('myalias')

    if occurrences == 1 && store_map('aliases')['myalias'] == 'echo second'
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Duplicate aliases allowed (found #{occurrences} occurrences)"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_alias_name_validation
    print "Test 7: Alias name validation... "

    # Try invalid names
    # Inner hyphens are allowed (zsh/bash/fish accept them); a leading one is not.
    output1, status1 = run_wayu('alias add -- "-bad" "echo test"')
    output2, status2 = run_wayu('alias add "a b" "echo test"')
    output3, status3 = run_wayu('alias add "if" "echo test"')

    # All should fail with validation errors
    invalid1 = status1.exitstatus == 65 && output1.include?("cannot start with '-'")
    ok_hyphen, ok_status = run_wayu('alias add "good-name" "echo test"')
    invalid1 &&= ok_status.success?
    invalid2 = status2.exitstatus == 65 && output2.include?("invalid character")
    invalid3 = !status3.success? && output3.include?("reserved")

    if invalid1 && invalid2 && invalid3
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Validation not working correctly"
      puts "  Dash test: #{invalid1}, Digit test: #{invalid2}, Reserved test: #{invalid3}"
      @failed += 1
    end
  end

  def test_alias_command_validation
    print "Test 8: Alias command validation... "

    # Try empty command
    output, status = run_wayu('alias add testalias ""')

    if !status.success? && (output.include?("cannot be empty") || output.include?("Missing required arguments"))
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Empty command should be rejected"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_complex_command
    print "Test 9: Complex command with pipes... "

    output, status = run_wayu('alias add findlarge "find . -type f -size +100M | sort -h"')

    if status.success? && store_map('aliases').key?('findlarge')
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to add complex command"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_multiline_command
    print "Test 10: Command with semicolons... "

    output, status = run_wayu('alias add multitest "cd /tmp; ls -la; pwd"')

    if status.success? && store_map('aliases').key?('multitest')
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to add command with semicolons"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_alias_with_special_chars
    print "Test 11: Alias with special characters... "

    output, status = run_wayu('alias add lsd "ls -la | grep ^d"')

    if status.success? && store_map('aliases').key?('lsd')
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to handle special characters"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_alias_persistence
    print "Test 12: Alias persistence after modifications... "

    # Add an alias
    run_wayu('alias add persistent1 "echo test1"')

    # Add another alias
    run_wayu('alias add persistent2 "echo test2"')
    aliases = store_map('aliases')

    # Both should exist
    if aliases.key?('persistent1') && aliases.key?('persistent2')
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Aliases not persisted correctly"
      @failed += 1
    end
  end

  def test_list_aliases_from_wayu_toml
    print "Test 13: List aliases from entries.json... "

    write_entries(aliases: { 'gs' => 'git status', 'gc' => 'git commit' })

    output, status = run_wayu("alias list")

    if status.success? && output.include?("gs") && output.include?("git status")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected alias list to read from entries.json"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_get_alias_from_wayu_toml
    print "Test 14: Get alias from entries.json... "

    write_entries(aliases: { 'ga' => 'git add' })

    output, status = run_wayu("alias get ga")

    if status.success? && output.strip == "git add"
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected 'git add', got '#{output.strip}'"
      @failed += 1
    end
  end

  def test_add_alias_to_wayu_toml
    print "Test 15: Add alias writes to entries.json only... "

    write_entries(aliases: { 'll' => 'ls -la' })
    toml_before = File.read("#{@config_dir}/wayu.toml")

    output, status = run_wayu('alias add gs "git status"')
    aliases = (read_entries['aliases'] || []).map { |a| [a['name'], a['value']] }

    if status.success? && aliases == [['ll', 'ls -la'], ['gs', 'git status']] &&
       File.read("#{@config_dir}/wayu.toml") == toml_before
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected alias add to append to entries.json and leave wayu.toml alone"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_remove_alias_from_wayu_toml
    print "Test 16: Remove alias writes to entries.json... "

    write_entries(aliases: { 'rmme' => 'echo bye', 'keepme' => 'echo stay' })

    output, status = run_wayu('alias rm rmme')
    aliases = store_map('aliases')

    if status.success? && !aliases.key?('rmme') && aliases['keepme'] == 'echo stay'
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected alias rm to update entries.json"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_help_command
    print "Test 13: Help command... "

    output, status = run_wayu("alias help")

    if output.include?("EXAMPLES") && output.include?("wayu alias")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Help output incomplete"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

end

# Run tests if executed directly
if __FILE__ == $0
  AliasIntegrationTest.new.run
end
