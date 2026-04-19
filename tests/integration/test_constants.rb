#!/usr/bin/env ruby
# Integration tests for constants command

require 'open3'
require 'fileutils'
require_relative 'test_helper'

class ConstantsIntegrationTest
  include WayuTestHelper

  def initialize
    setup_test_env
    @toml_file = "#{@config_dir}/wayu.toml"
  end

  def run
    puts "🔢 Testing constants command integration..."
    puts

    begin
      build_project
      initialize_wayu

      test_add_simple_constant
      test_add_constant_with_spaces
      test_add_constant_with_special_chars
      test_list_constants
      test_get_constant
      test_get_constant_not_found
      test_get_constant_empty_name
      test_get_constant_unescapes_value
      test_remove_constant
      test_duplicate_constant_handling
      test_constant_name_validation
      test_lowercase_constant_warning
      test_constant_value_with_quotes
      test_constant_with_numbers
      test_multiline_value_handling
      test_constant_persistence
      test_list_constants_from_wayu_toml_env
      test_get_constant_from_wayu_toml_constants
      test_add_constant_to_wayu_toml
      test_remove_constant_from_wayu_toml
      test_help_command
      test_const_alias
    ensure
      teardown_test_env
    end

    print_summary("constants")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def test_add_simple_constant
    print "Test 1: Add simple constant... "

    output, status = run_wayu('constants add MY_VAR "test_value"')

    if status.success? && File.read(@toml_file).include?('MY_VAR = ')
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

    if status.success? && File.read(@toml_file).include?('MY_PATH = ')
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

    if status.success? && File.read(@toml_file).include?('API_KEY = ')
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

  def test_get_constant
    print "Test 5a: Get constant value (happy path)... "

    run_wayu('constants add GET_TEST "hello_world"')
    output, status = run_wayu("constants get GET_TEST")

    if status.success? && output.strip == "hello_world"
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected 'hello_world', got '#{output.strip}'"
      puts "  Exit status: #{status.exitstatus}"
      @failed += 1
    end
  end

  def test_get_constant_not_found
    print "Test 5b: Get non-existent constant returns error... "

    output, status = run_wayu("constants get NONEXISTENT_XYZ_123")

    if !status.success? && status.exitstatus == 65
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected exit 65, got #{status.exitstatus}"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_get_constant_empty_name
    print "Test 5c: Get with empty name returns usage error... "

    output, status = run_wayu('constants get ""')

    if !status.success? && status.exitstatus == 64
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected exit 64 (usage), got #{status.exitstatus}"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_get_constant_unescapes_value
    print "Test 5d: Get unescapes shell-escaped values... "

    # Add a constant with quotes — sanitize_shell_value stores them as \"
    run_wayu('constants add ESCAPE_TEST \'say "hello"\'')
    output, status = run_wayu("constants get ESCAPE_TEST")
    run_wayu("constants rm ESCAPE_TEST")

    expected = 'say "hello"'
    if status.success? && output.strip == expected
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected: #{expected.inspect}"
      puts "  Got:      #{output.strip.inspect}"
      @failed += 1
    end
  end

  def test_remove_constant
    print "Test 5: Remove constant... "

    output, status = run_wayu("constants rm MY_VAR")

    constants_content = File.read(@toml_file)
    if status.success? && !constants_content.include?('MY_VAR = ')
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
    constants_content = File.read(@toml_file)
    occurrences = constants_content.scan(/DUPLICATE_TEST = /).length

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

    if status.success? && File.read(@toml_file).include?('QUOTED_VALUE = ')
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

    if status.success? && File.read(@toml_file).include?('VERSION_2024 = ')
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
    content_before = File.read(@toml_file)

    # Add another constant
    run_wayu('constants add PERSIST_TEST_2 "value2"')
    content_after = File.read(@toml_file)

    # Both should exist
    if content_after.include?('PERSIST_TEST_1 = ') && content_after.include?('PERSIST_TEST_2 = ')
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Constants not persisted correctly"
      @failed += 1
    end
  end

  def test_list_constants_from_wayu_toml_env
    print "Test 16: List constants from wayu.toml [env]... "

    File.write("#{@config_dir}/wayu.toml", <<~TOML)
      [env]
      FROM_TOML = "loaded"
      SECOND_VAR = "also_loaded"
    TOML

    output, status = run_wayu("constants list")

    if status.success? && output.include?("FROM_TOML") && output.include?("loaded")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected constants list to read from wayu.toml [env]"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_get_constant_from_wayu_toml_constants
    print "Test 17: Get constant from wayu.toml [constants]... "

    File.write("#{@config_dir}/wayu.toml", <<~TOML)
      [constants]
      TOML_ONLY = "from_table"
    TOML

    output, status = run_wayu("constants get TOML_ONLY")

    if status.success? && output.strip == "from_table"
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected 'from_table', got '#{output.strip}'"
      @failed += 1
    end
  end

  def test_add_constant_to_wayu_toml
    print "Test 18: Add constant writes to wayu.toml... "

    File.write("#{@config_dir}/wayu.toml", <<~TOML)
      [constants]
      EXISTING = "value"
    TOML

    output, status = run_wayu('constants add TOML_ADDED "new_value"')
    toml = File.read("#{@config_dir}/wayu.toml")

    if status.success? && toml.include?('TOML_ADDED = "new_value"')
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected constants add to update wayu.toml only"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_remove_constant_from_wayu_toml
    print "Test 19: Remove constant writes to wayu.toml... "

    File.write("#{@config_dir}/wayu.toml", <<~TOML)
      [constants]
      REMOVE_ME = "bye"
      KEEP_ME = "stay"
    TOML

    output, status = run_wayu('constants rm REMOVE_ME')
    toml = File.read("#{@config_dir}/wayu.toml")

    if status.success? && !toml.include?('REMOVE_ME =') && toml.include?('KEEP_ME = "stay"')
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected constants rm to update wayu.toml"
      puts "  Output: #{output}"
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

  def test_const_alias
    print "Test 14: 'const' alias behaves identically to 'constants'... "

    File.write("#{@config_dir}/wayu.toml", <<~TOML)
      [constants]
      BASE = "value"
    TOML

    run_wayu('const add CONST_ALIAS_TEST "alias_value"')
    toml_after_add = File.read("#{@config_dir}/wayu.toml")
    added = toml_after_add.include?('CONST_ALIAS_TEST = "alias_value"')

    list_out, list_status = run_wayu("const list")
    listed = list_status.success? && list_out.include?("CONST_ALIAS_TEST")

    get_out, get_status = run_wayu("const get CONST_ALIAS_TEST")
    got = get_status.success? && get_out.strip == "alias_value"

    run_wayu("const rm CONST_ALIAS_TEST")
    removed = !File.read("#{@config_dir}/wayu.toml").include?('CONST_ALIAS_TEST =')

    if added && listed && got && removed
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  const alias failed (add=#{added}, list=#{listed}, get=#{got}, rm=#{removed})"
      @failed += 1
    end
  end

end

# Run tests if executed directly
if __FILE__ == $0
  ConstantsIntegrationTest.new.run
end
