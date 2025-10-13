#!/usr/bin/env ruby
# Integration tests for constants command

require 'open3'
require 'fileutils'

class ConstantsIntegrationTest
  attr_reader :passed, :failed

  def initialize
    @passed = 0
    @failed = 0
    @wayu_bin = './bin/wayu'
    @config_dir = File.expand_path('~/.config/wayu')
    @config_backup = File.expand_path('~/.config/wayu.backup')
    @constants_file = "#{@config_dir}/constants.zsh"
  end

  def run
    puts "🔢 Testing constants command integration..."
    puts

    build_project
    backup_config
    initialize_wayu

    test_add_simple_constant
    test_add_constant_with_spaces
    test_add_constant_with_special_chars
    test_list_constants
    test_remove_constant
    test_duplicate_constant_handling
    test_constant_name_validation
    test_lowercase_constant_warning
    test_constant_value_with_quotes
    test_constant_with_numbers
    test_multiline_value_handling
    test_constant_persistence
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

  def test_add_simple_constant
    print "Test 1: Add simple constant... "

    output, status = run_wayu('constants add MY_VAR "test_value"')

    if status.success? && File.read(@constants_file).include?('export MY_VAR=')
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to add simple constant"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_add_constant_with_spaces
    print "Test 2: Add constant with spaces in value... "

    output, status = run_wayu('constants add MY_PATH "/usr/local/my path"')

    if status.success? && File.read(@constants_file).include?('export MY_PATH=')
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to add constant with spaces"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_add_constant_with_special_chars
    print "Test 3: Add constant with special characters... "

    output, status = run_wayu('constants add API_KEY "abc-123_xyz.789"')

    if status.success? && File.read(@constants_file).include?('export API_KEY=')
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to add constant with special chars"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_list_constants
    print "Test 4: List all constants... "

    output, status = run_wayu("constants list")

    # Should show our test constants
    if status.success? && output.include?("MY_VAR")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  List command failed or missing constants"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_remove_constant
    print "Test 5: Remove constant... "

    output, status = run_wayu("constants rm MY_VAR")

    constants_content = File.read(@constants_file)
    if status.success? && !constants_content.include?('export MY_VAR=')
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to remove constant"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_duplicate_constant_handling
    print "Test 6: Duplicate constant handling... "

    # Add constant twice
    run_wayu('constants add DUPLICATE_TEST "first"')
    output, status = run_wayu('constants add DUPLICATE_TEST "second"')

    # Should either prevent duplicate or overwrite
    constants_content = File.read(@constants_file)
    occurrences = constants_content.scan(/export DUPLICATE_TEST=/).length

    if occurrences == 1
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Duplicate constants allowed (found #{occurrences} occurrences)"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_constant_name_validation
    print "Test 7: Constant name validation... "

    # Try invalid names
    output1, status1 = run_wayu('constants add "bad-name" "value"')
    output2, status2 = run_wayu('constants add "123ABC" "value"')
    output3, status3 = run_wayu('constants add "while" "value"')

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

  def test_lowercase_constant_warning
    print "Test 8: Lowercase constant warning... "

    output, status = run_wayu('constants add my_lowercase_var "value"')

    # Should show warning but may succeed
    if output.include?("lowercase") || output.include?("Warning") || output.include?("UPPER")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Should warn about lowercase in constant name"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_constant_value_with_quotes
    print "Test 9: Constant value with quotes... "

    output, status = run_wayu('constants add QUOTED_VALUE "\"Hello, World!\""')

    if status.success? && File.read(@constants_file).include?('export QUOTED_VALUE=')
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to handle quotes in value"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_constant_with_numbers
    print "Test 10: Constant with numbers... "

    output, status = run_wayu('constants add VERSION_2024 "1.2.3"')

    if status.success? && File.read(@constants_file).include?('export VERSION_2024=')
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to add constant with numbers"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_multiline_value_handling
    print "Test 11: Value with newline characters... "

    # Try to add value with \n (should handle gracefully)
    output, status = run_wayu('constants add MULTILINE "line1\nline2"')

    # Should either succeed with proper escaping or show error
    if status.success? || output.include?("invalid") || output.include?("newline")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Unexpected handling of newlines"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_constant_persistence
    print "Test 12: Constant persistence after modifications... "

    # Add a constant
    run_wayu('constants add PERSIST_TEST_1 "value1"')
    content_before = File.read(@constants_file)

    # Add another constant
    run_wayu('constants add PERSIST_TEST_2 "value2"')
    content_after = File.read(@constants_file)

    # Both should exist
    if content_after.include?('export PERSIST_TEST_1=') && content_after.include?('export PERSIST_TEST_2=')
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Constants not persisted correctly"
      @failed += 1
    end
  end

  def test_help_command
    print "Test 13: Help command... "

    output, status = run_wayu("constants help")

    if output.include?("EXAMPLES") && output.include?("wayu constants")
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
      puts "✓ All #{total} constants integration tests passed!"
    else
      puts "Results: #{@passed}/#{total} tests passed, #{@failed} failed"
    end
    puts "━" * 50
  end
end

# Run tests if executed directly
if __FILE__ == $0
  ConstantsIntegrationTest.new.run
end
