#!/usr/bin/env ruby
# Integration tests for alias command

require 'open3'
require 'fileutils'
require_relative 'test_helper'

class AliasIntegrationTest
  include WayuTestHelper

  def initialize
    setup_test_env
    @alias_file = "#{@config_dir}/aliases.zsh"
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
      test_help_command
    ensure
      teardown_test_env
    end

    print_summary("alias")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def test_add_simple_alias
    print "Test 1: Add simple alias... "

    output, status = run_wayu('alias add ll "ls -la"')

    if status.success? && File.read(@alias_file).include?('alias ll=')
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

    if status.success? && File.read(@alias_file).include?('alias greet=')
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

    alias_content = File.read(@alias_file)
    if status.success? && alias_content.include?('alias gco=')
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

    alias_content = File.read(@alias_file)
    if status.success? && !alias_content.include?('alias ll=')
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
    alias_content = File.read(@alias_file)
    occurrences = alias_content.scan(/alias myalias=/).length

    if occurrences == 1
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
    output1, status1 = run_wayu('alias add "bad-name" "echo test"')
    output2, status2 = run_wayu('alias add "123abc" "echo test"')
    output3, status3 = run_wayu('alias add "if" "echo test"')

    # All should fail with validation errors
    invalid1 = !status1.success? && (output1.include?("invalid") || output1.include?("Invalid"))
    invalid2 = !status2.success? && output2.include?("must start with")
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

    if status.success? && File.read(@alias_file).include?('alias findlarge=')
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

    if status.success? && File.read(@alias_file).include?('alias multitest=')
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

    if status.success? && File.read(@alias_file).include?('alias lsd=')
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
    content_before = File.read(@alias_file)

    # Add another alias
    run_wayu('alias add persistent2 "echo test2"')
    content_after = File.read(@alias_file)

    # Both should exist
    if content_after.include?('alias persistent1=') && content_after.include?('alias persistent2=')
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Aliases not persisted correctly"
      @failed += 1
    end
  end

  def test_list_aliases_from_wayu_toml
    print "Test 13: List aliases from wayu.toml... "

    File.write("#{@config_dir}/wayu.toml", <<~TOML)
      [aliases]
      gs = "git status"
      gc = "git commit"
    TOML

    output, status = run_wayu("alias list")

    if status.success? && output.include?("gs") && output.include?("git status")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected alias list to read from wayu.toml"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_get_alias_from_wayu_toml
    print "Test 14: Get alias from wayu.toml... "

    File.write("#{@config_dir}/wayu.toml", <<~TOML)
      [aliases]
      ga = "git add"
    TOML

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
    print "Test 15: Add alias writes to wayu.toml... "

    File.write("#{@config_dir}/wayu.toml", <<~TOML)
      [aliases]
      ll = "ls -la"
    TOML

    output, status = run_wayu('alias add gs "git status"')
    toml = File.read("#{@config_dir}/wayu.toml")

    if status.success? && toml.include?('gs = "git status"') && !File.read(@alias_file).include?('alias gs=')
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected alias add to update wayu.toml only"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_remove_alias_from_wayu_toml
    print "Test 16: Remove alias writes to wayu.toml... "

    File.write("#{@config_dir}/wayu.toml", <<~TOML)
      [aliases]
      rmme = "echo bye"
      keepme = "echo stay"
    TOML

    output, status = run_wayu('alias rm rmme')
    toml = File.read("#{@config_dir}/wayu.toml")

    if status.success? && !toml.include?('rmme =') && toml.include?('keepme = "echo stay"')
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected alias rm to update wayu.toml"
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
