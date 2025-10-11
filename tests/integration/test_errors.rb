#!/usr/bin/env ruby
# Integration tests for enhanced error messages

require 'open3'
require 'fileutils'
require 'tempfile'

class ErrorsIntegrationTest
  attr_reader :passed, :failed

  def initialize
    @passed = 0
    @failed = 0
    @wayu_bin = './bin/wayu'
    @config_dir = File.expand_path('~/.config/wayu')
    @config_backup = File.expand_path('~/.config/wayu.backup')
  end

  def run
    puts "🚨 Testing enhanced error messages integration..."
    puts

    build_project

    test_file_not_found_error
    test_permission_denied_error
    test_config_not_initialized_error
    test_directory_not_found_error
    test_invalid_input_error
    test_contextual_help_messages
    test_recovery_commands
    test_error_categorization

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

  def test_file_not_found_error
    print "Test 1: File not found error with context... "

    # Try to add a completion with non-existent file
    fake_file = "/tmp/nonexistent_file_#{Time.now.to_i}"
    output, status = run_wayu("completions add test #{fake_file}")

    if output.include?("File not found") && output.include?(fake_file)
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected contextual file not found error"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_permission_denied_error
    print "Test 2: Permission denied error... "

    # Create a file without read permissions
    temp_file = Tempfile.new('test_perm')
    temp_file.write("test content")
    temp_file.flush
    File.chmod(0000, temp_file.path)

    begin
      output, status = run_wayu("completions add test #{temp_file.path}")

      if output.include?("Permission denied") || output.include?("Failed to read")
        puts "✓"
        @passed += 1
      else
        puts "✗"
        puts "  Expected permission denied error"
        puts "  Output: #{output}"
        @failed += 1
      end
    ensure
      File.chmod(0644, temp_file.path) rescue nil
      temp_file.close!
    end
  end

  def test_config_not_initialized_error
    print "Test 3: Config not initialized error... "

    # Temporarily rename config if it exists
    config_moved = false
    if Dir.exist?(@config_dir)
      FileUtils.mv(@config_dir, @config_backup)
      config_moved = true
    end

    begin
      output, status = run_wayu("path list")

      if output.include?("not initialized") || output.include?("wayu init")
        puts "✓"
        @passed += 1
      else
        puts "✗"
        puts "  Expected config not initialized error"
        puts "  Output: #{output}"
        @failed += 1
      end
    ensure
      if config_moved && Dir.exist?(@config_backup)
        FileUtils.mv(@config_backup, @config_dir)
      end
    end
  end

  def test_directory_not_found_error
    print "Test 4: Directory not found error... "

    fake_dir = "/nonexistent_directory_#{Time.now.to_i}"
    output, status = run_wayu("path add #{fake_dir}")

    if output.include?("does not exist") || output.include?("Directory not found")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected directory not found error"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_invalid_input_error
    print "Test 5: Invalid input error... "

    output, status = run_wayu('alias add "bad;name" "command"')

    if output.include?("Invalid") && output.include?("contains invalid characters")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected invalid input error"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_contextual_help_messages
    print "Test 6: Contextual help in error messages... "

    # Test that errors include helpful next steps
    output, status = run_wayu("completions rm nonexistent")

    if output.include?("wayu completions list") || output.include?("to see available")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected contextual help message"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_recovery_commands
    print "Test 7: Recovery commands in errors... "

    # Temporarily rename config
    config_moved = false
    if Dir.exist?(@config_dir)
      FileUtils.mv(@config_dir, @config_backup)
      config_moved = true
    end

    begin
      output, status = run_wayu("alias list")

      if output.include?("wayu init") || output.include?("initialize")
        puts "✓"
        @passed += 1
      else
        puts "✗"
        puts "  Expected recovery command suggestion"
        puts "  Output: #{output}"
        @failed += 1
      end
    ensure
      if config_moved && Dir.exist?(@config_backup)
        FileUtils.mv(@config_backup, @config_dir)
      end
    end
  end

  def test_error_categorization
    print "Test 8: Proper error categorization... "

    # Test multiple error types are properly categorized
    errors_found = []

    # File error
    output1, _ = run_wayu("completions add test /fake/file")
    errors_found << "file" if output1.include?("File not found") || output1.include?("does not exist")

    # Input error
    output2, _ = run_wayu('alias add "if" "cmd"')
    errors_found << "input" if output2.include?("reserved") || output2.include?("Invalid")

    # Directory error
    output3, _ = run_wayu("path add /fake/dir")
    errors_found << "dir" if output3.include?("does not exist") || output3.include?("Directory")

    if errors_found.length >= 2
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected multiple error categories, found: #{errors_found.join(', ')}"
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
      puts "✓ All #{total} error handling integration tests passed!"
    else
      puts "Results: #{@passed}/#{total} tests passed, #{@failed} failed"
    end
    puts "━" * 50
  end
end

# Run tests if executed directly
if __FILE__ == $0
  ErrorsIntegrationTest.new.run
end