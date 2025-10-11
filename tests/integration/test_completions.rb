#!/usr/bin/env ruby
# Integration tests for completions command

require 'fileutils'
require 'open3'
require 'tempfile'

class CompletionsIntegrationTest
  attr_reader :passed, :failed

  def initialize
    @passed = 0
    @failed = 0
    @wayu_bin = './bin/wayu'
    @completions_dir = File.expand_path('~/.config/wayu/completions')
  end

  def run
    puts "📋 Testing completions command integration..."
    puts

    build_project
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

    cleanup
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

    # Count completion entries (lines starting with number and underscore)
    # Handle potential encoding issues
    begin
      count = output.scan(/^\s*\d+\.\s*_/).length
    rescue ArgumentError => e
      # If encoding issue, try to count a different way
      count = output.lines.select { |line| line =~ /^\s*\d+\.\s*_/ rescue false }.length
    end

    if count >= 2
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected at least 2 completions, found #{count}"
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

    if output.include?("Completions Command") && output.include?("EXAMPLES")
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

    if output.include?("No completions installed")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Should show 'No completions installed'"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def cleanup
    @test_file.close! if @test_file
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
      puts "✓ All #{total} completions integration tests passed!"
    else
      puts "Results: #{@passed}/#{total} tests passed, #{@failed} failed"
    end
    puts "━" * 50
  end
end

# Run tests if executed directly
if __FILE__ == $0
  CompletionsIntegrationTest.new.run
end