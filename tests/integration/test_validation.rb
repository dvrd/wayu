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
      test_alias_valid_input
      test_constant_valid_input
      test_path_valid_input
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

  def test_path_dangerous_chars
    print "Test 5: Sanitize dangerous characters in path... "

    # Create a test directory with spaces
    test_dir = "/tmp/test dir #{Time.now.to_i}"
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
