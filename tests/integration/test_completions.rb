#!/usr/bin/env ruby
# Integration tests for completions command

require 'fileutils'
require 'open3'
require 'tempfile'
require_relative 'test_helper'

class CompletionsIntegrationTest
  include WayuTestHelper

  def initialize
    setup_test_env
    @completions_dir = "#{@config_dir}/completions"
  end

  def run
    puts "📋 Testing completions command integration..."
    puts

    begin
      build_project
      initialize_wayu
      create_test_completion_file

      test_add_completion
      test_list_completions
      test_add_without_underscore
      test_list_multiple
      test_remove_specific
      test_remove_nonexistent
      test_invalid_source
      test_help_command
      test_content_preservation
      test_empty_state
    ensure
      cleanup
      teardown_test_env
    end

    print_summary("completions")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def create_test_completion_file
    print "Creating test completion file..."
    @test_file = Tempfile.new(['_testcomp', ''])
    @test_file.write(<<~EOF)
      #compdef testcomp
      # Test completion for wayu integration test

      _testcomp() {
          local context state line
          _arguments -C \\
              '1:command:(init add remove list help)' \\
              '*::arg:->args'

          case $state in
              args)
                  case $line[1] in
                      add)
                          _arguments '1:name:' '2:file:_files'
                          ;;
                      remove)
                          _arguments '1:name:(foo bar baz)'
                          ;;
                  esac
                  ;;
          esac
      }

      _testcomp "$@"
    EOF
    @test_file.flush
    puts " ✓"
    puts
  end

  def test_add_completion
    print "Test 1: Add completion... "
    output, status = run_wayu("completions add testcomp #{@test_file.path}")

    if File.exist?("#{@completions_dir}/_testcomp")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Completion file not found at #{@completions_dir}/_testcomp"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_list_completions
    print "Test 2: List completions... "
    output, status = run_wayu("completions list")

    if output.include?("_testcomp") && output.include?("Shell Completions")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Completion not found in list"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_add_without_underscore
    print "Test 3: Add completion without underscore prefix... "
    output, status = run_wayu("completions add mycomp #{@test_file.path}")

    if File.exist?("#{@completions_dir}/_mycomp")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  File not created with underscore prefix"
      @failed += 1
    end
  end

  def test_list_multiple
    print "Test 4: List shows multiple completions... "
    output, status = run_wayu("completions list")

    # Check that our test completions are present
    has_testcomp = output.include?("_testcomp")
    has_mycomp = output.include?("_mycomp")

    if has_testcomp && has_mycomp
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected both _testcomp and _mycomp to be present"
      puts "  Has _testcomp: #{has_testcomp}, Has _mycomp: #{has_mycomp}"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_remove_specific
    print "Test 5: Remove specific completion... "
    output, status = run_wayu("completions rm testcomp")

    if !File.exist?("#{@completions_dir}/_testcomp")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Completion file still exists"
      @failed += 1
    end
  end

  def test_remove_nonexistent
    print "Test 6: Try to remove non-existent completion... "
    output, status = run_wayu("completions rm nonexistent")

    if output.include?("Completion not found")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected 'Completion not found' error"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_invalid_source
    print "Test 7: Add completion with invalid source file... "
    output, status = run_wayu("completions add invalid /tmp/nonexistent-file-#{Time.now.to_i}")

    if output.include?("File not found") || output.include?("does not exist")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected 'File not found' error"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_help_command
    print "Test 8: Help command... "
    output, status = run_wayu("completions help")

    if output.include?("wayu completions") && output.include?("EXAMPLES")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Help output incomplete"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_content_preservation
    print "Test 9: Verify completion file content preservation... "

    if File.exist?("#{@completions_dir}/_mycomp")
      content = File.read("#{@completions_dir}/_mycomp")
      if content.include?("#compdef testcomp")
        puts "✓"
        @passed += 1
      else
        puts "✗"
        puts "  Completion file content corrupted"
        @failed += 1
      end
    else
      puts "✗"
      puts "  Completion file missing"
      @failed += 1
    end
  end

  def test_empty_state
    print "Test 10: Clean up and verify empty state... "

    # Remove remaining completion
    run_wayu("completions rm mycomp")

    output, status = run_wayu("completions list")

    # Check that our test completions are removed (system completions may remain)
    has_testcomp = output.include?("_testcomp")
    has_mycomp = output.include?("_mycomp")

    if !has_testcomp && !has_mycomp
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Test completions should be removed"
      puts "  Has _testcomp: #{has_testcomp}, Has _mycomp: #{has_mycomp}"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def cleanup
    @test_file.close! if @test_file
  end

end

# Run tests if executed directly
if __FILE__ == $0
  CompletionsIntegrationTest.new.run
end
