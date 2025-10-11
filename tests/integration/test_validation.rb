#!/usr/bin/env ruby
# Integration tests for input validation

require 'open3'
require 'tempfile'

class ValidationIntegrationTest
  attr_reader :passed, :failed

  def initialize
    @passed = 0
    @failed = 0
    @wayu_bin = './bin/wayu'
    @config_backup = File.expand_path('~/.config/wayu.backup')
    @config_dir = File.expand_path('~/.config/wayu')
  end

  def run
    puts "🔒 Testing input validation integration..."
    puts

    build_project
    backup_config
    initialize_wayu

    test_alias_shell_reserved
    test_alias_dangerous_chars
    test_constant_shell_reserved
    test_constant_lowercase_warning
    test_path_dangerous_chars
    test_alias_valid_input
    test_constant_valid_input
    test_path_valid_input

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

    if output.include?("Invalid") || output.include?("contains invalid characters")
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

    if status.success? && output.include?("Added alias")
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

    if status.success? && output.include?("Added constant")
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

    if status.success? && output.include?("Added to PATH")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to add valid path"
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
      puts "✓ All #{total} validation integration tests passed!"
    else
      puts "Results: #{@passed}/#{total} tests passed, #{@failed} failed"
    end
    puts "━" * 50
  end
end

# Run tests if executed directly
if __FILE__ == $0
  ValidationIntegrationTest.new.run
end