#!/usr/bin/env ruby
# Integration tests for path command

require 'open3'
require 'fileutils'
require_relative 'test_helper'

class PathIntegrationTest
  include WayuTestHelper

  def initialize
    setup_test_env
    @toml_file = "#{@config_dir}/wayu.toml"
  end

  def run
    puts "🛤️  Testing PATH command integration..."
    puts

    begin
      build_project
      initialize_wayu

      test_add_single_path
      test_add_multiple_paths
      test_list_paths
      test_remove_path_by_name
      test_duplicate_path_handling
      test_path_order_preservation
      test_relative_path_resolution
      test_path_with_spaces
      test_symlink_handling
      test_nonexistent_path_handling
      test_remove_nonexistent_path
      test_path_persistence_after_modifications
      test_help_command
    ensure
      teardown_test_env
    end

    print_summary("PATH")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def test_add_single_path
    print "Test 1: Add single path... "

    test_dir = "/tmp/wayu_test_path1"
    Dir.mkdir(test_dir) unless Dir.exist?(test_dir)

    output, status = run_wayu("path add #{test_dir}")

    if status.success? && File.read(@toml_file).include?("path = \"#{test_dir}\"")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to add path"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_add_multiple_paths
    print "Test 2: Add multiple paths... "

    test_dirs = ["/tmp/wayu_test_path2", "/tmp/wayu_test_path3", "/tmp/wayu_test_path4"]
    test_dirs.each { |dir| Dir.mkdir(dir) unless Dir.exist?(dir) }

    test_dirs.each { |dir| run_wayu("path add #{dir}") }

    path_content = File.read(@toml_file)
    all_present = test_dirs.all? { |dir| path_content.include?("path = \"#{dir}\"") }

    if all_present
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Not all paths were added"
      @failed += 1
    end
  end

  def test_list_paths
    print "Test 3: List all paths... "

    output, status = run_wayu("path list")

    # Should show table and at least our test paths
    if status.success? && output.include?("/tmp/wayu_test_path")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  List command failed or missing entries"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_remove_path_by_name
    print "Test 4: Remove path by name... "

    test_dir = "/tmp/wayu_test_path1"
    output, status = run_wayu("path rm #{test_dir}")

    path_content = File.read(@toml_file)
    if status.success? && !path_content.include?("path = \"#{test_dir}\"")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to remove path"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_duplicate_path_handling
    print "Test 5: Duplicate path handling... "

    test_dir = "/tmp/wayu_test_duplicate"
    Dir.mkdir(test_dir) unless Dir.exist?(test_dir)

    # Add path twice
    run_wayu("path add #{test_dir}")
    output, status = run_wayu("path add #{test_dir}")

    # Should either prevent duplicate or warn
    path_content = File.read(@toml_file)
    occurrences = path_content.scan(/#{Regexp.escape(test_dir)}/).length

    if occurrences == 1 || output.include?("already") || output.include?("exists")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Duplicate paths allowed (found #{occurrences} occurrences)"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_path_order_preservation
    print "Test 6: Path order preservation... "

    # Clean up and add paths in specific order
    test_dirs = ["/tmp/wayu_order1", "/tmp/wayu_order2", "/tmp/wayu_order3"]
    test_dirs.each { |dir| Dir.mkdir(dir) unless Dir.exist?(dir) }

    # Remove all test paths first
    Dir.glob("/tmp/wayu_*").each { |dir| run_wayu("path rm #{dir}") }

    # Add in order
    test_dirs.each { |dir| run_wayu("path add #{dir}") }

    path_content = File.read(@toml_file)
    order1_pos = path_content.index("wayu_order1")
    order2_pos = path_content.index("wayu_order2")
    order3_pos = path_content.index("wayu_order3")

    if order1_pos && order2_pos && order3_pos &&
       order1_pos < order2_pos && order2_pos < order3_pos
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Path order not preserved"
      @failed += 1
    end
  end

  def test_relative_path_resolution
    print "Test 7: Relative path resolution... "

    # Try to add a relative path
    output, status = run_wayu("path add .")

    # Should resolve to absolute path or show error
    if status.success? || output.include?("absolute") || output.include?("does not exist")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Relative path handling unclear"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_path_with_spaces
    print "Test 8: Path with spaces... "

    test_dir = "/tmp/wayu test with spaces"
    Dir.mkdir(test_dir) unless Dir.exist?(test_dir)

    output, status = run_wayu("path add \"#{test_dir}\"")

    if status.success?
      path_content = File.read(@toml_file)
      # Should handle spaces correctly (either quoted or escaped)
      if path_content.include?("wayu test with spaces")
        puts "✓"
        @passed += 1
      else
        puts "✗"
        puts "  Path with spaces not properly stored"
        @failed += 1
      end
    else
      puts "✗"
      puts "  Failed to add path with spaces"
      puts "  Output: #{output}"
      @failed += 1
    end

    FileUtils.rm_rf(test_dir) if Dir.exist?(test_dir)
  end

  def test_symlink_handling
    print "Test 9: Symlink handling... "

    real_dir = "/tmp/wayu_real_dir"
    link_dir = "/tmp/wayu_link_dir"

    Dir.mkdir(real_dir) unless Dir.exist?(real_dir)
    File.symlink(real_dir, link_dir) unless File.exist?(link_dir)

    output, status = run_wayu("path add #{link_dir}")

    if status.success?
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to handle symlink"
      puts "  Output: #{output}"
      @failed += 1
    end

    File.delete(link_dir) if File.symlink?(link_dir)
    FileUtils.rm_rf(real_dir) if Dir.exist?(real_dir)
  end

  def test_nonexistent_path_handling
    print "Test 10: Non-existent path handling... "

    fake_path = "/tmp/nonexistent_wayu_path_#{Time.now.to_i}"
    output, status = run_wayu("path add #{fake_path}")

    if !status.success? && (output.include?("does not exist") || output.include?("not found") || output.include?("Could not resolve"))
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Should reject non-existent path"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_remove_nonexistent_path
    print "Test 11: Remove non-existent path... "

    fake_path = "/nonexistent/path/for/removal"
    output, status = run_wayu("path rm #{fake_path}")

    if output.include?("not found") || output.include?("does not exist")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Should show error for non-existent path removal"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_path_persistence_after_modifications
    print "Test 12: Path persistence after modifications... "

    # Add a path
    test_dir = "/tmp/wayu_persist_test"
    Dir.mkdir(test_dir) unless Dir.exist?(test_dir)
    run_wayu("path add #{test_dir}")

    # Read content
    content_before = File.read(@toml_file)

    # Add another path (triggers file write)
    test_dir2 = "/tmp/wayu_persist_test2"
    Dir.mkdir(test_dir2) unless Dir.exist?(test_dir2)
    run_wayu("path add #{test_dir2}")

    # Check both paths still exist
    content_after = File.read(@toml_file)

    if content_after.include?(test_dir) && content_after.include?(test_dir2)
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Paths not persisted correctly"
      @failed += 1
    end
  end

  def test_help_command
    print "Test 13: Help command... "

    output, status = run_wayu("path help")

    if output.include?("EXAMPLES") && output.include?("wayu path")
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
  PathIntegrationTest.new.run
end
