#!/usr/bin/env ruby
# Integration tests for alias command

require 'open3'
require 'fileutils'

class AliasIntegrationTest
  attr_reader :passed, :failed

  def initialize
    @passed = 0
    @failed = 0
    @wayu_bin = './bin/wayu'
    @config_dir = File.expand_path('~/.config/wayu')
    @config_backup = File.expand_path('~/.config/wayu.backup')
    @alias_file = "#{@config_dir}/aliases.zsh"
  end

  def run
    puts "🔗 Testing alias command integration..."
    puts

    build_project
    backup_config
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
    test_help_command

    restore_config
    print_summary
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def build_project
    print "Building wayu..."
    stdout, stderr, status = Open3.capture3('task build')
    if status.success?
      puts " ✓"
    else
      puts " ✗"
      puts "Build failed: #{stderr}"
      exit 1
    end
    puts
  end

  def backup_config
    if Dir.exist?(@config_dir)
      print "Backing up existing config..."
      if Dir.exist?(@config_backup)
        FileUtils.rm_rf(@config_backup)
      end
      FileUtils.mv(@config_dir, @config_backup)
      puts " ✓"
    end
  end

  def initialize_wayu
    print "Initializing wayu config..."
    output, status = run_wayu("init")
    if status.success?
      puts " ✓"
    else
      puts " ✗"
      puts "Init failed: #{output}"
      restore_config
      exit 1
    end
    puts
  end

  def restore_config
    print "\nRestoring original config..."
    if Dir.exist?(@config_dir)
      FileUtils.rm_rf(@config_dir)
    end
    if Dir.exist?(@config_backup)
      FileUtils.mv(@config_backup, @config_dir)
    end
    puts " ✓"
  end

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

    if !status.success? && output.include?("cannot be empty")
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

  def run_wayu(args)
    stdout, stderr, status = Open3.capture3("#{@wayu_bin} #{args}")
    # Force UTF-8 encoding for the output
    stdout = stdout.force_encoding('UTF-8') if stdout
    stderr = stderr.force_encoding('UTF-8') if stderr
    # Return combined output for easier checking
    [stdout + stderr, status]
  end

  def print_summary
    puts
    puts "━" * 50
    total = @passed + @failed
    if @failed == 0
      puts "✓ All #{total} alias integration tests passed!"
    else
      puts "Results: #{@passed}/#{total} tests passed, #{@failed} failed"
    end
    puts "━" * 50
  end
end

# Run tests if executed directly
if __FILE__ == $0
  AliasIntegrationTest.new.run
end
