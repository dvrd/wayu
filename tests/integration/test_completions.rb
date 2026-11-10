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
    @completions_dir = "#{@data_dir}/completions"
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
      test_bash_completes_existing_entries
      test_fish_completes_existing_entries
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

    if status.exitstatus == 66 && output.include?("File not found")
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

  # OKAMI-181: `wayu <cmd> rm|get|… <TAB>` offers the existing entries
  # (listed by the hidden `completions names <kind>`) in bash.
  def test_bash_completes_existing_entries
    print "Test 11: bash completes existing aliases/consts/paths... "
    run_wayu("alias add gst 'git status'")
    run_wayu("const add DYN_CONST 1")
    script, = run_wayu("completions bash")
    names, = run_wayu("completions names alias")
    file = "#{@tmp_home}/wayu.bash"
    File.write(file, script)
    env = ENV.to_h.merge('HOME' => @tmp_home, '_WAYU_BIN' => @wayu_bin)
    probe = <<~'SH'
      source "$1"
      t() { COMP_WORDS=("$@"); COMP_CWORD=$((${#COMP_WORDS[@]}-1)); COMPREPLY=(); _wayu_completion; echo "${COMPREPLY[*]}"; }
      t wayu alias rm ""
      t wayu const get DYN
      t wayu alias rm gst ""
      t wayu alias ""
    SH
    out, _err, st = Open3.capture3(env, 'bash', '--norc', '-c', probe, 'probe', file)
    lines = out.lines.map(&:chomp)
    ok = st.success? && names.lines.map(&:chomp).include?('gst') &&
         lines[0].split.include?('gst') && lines[1] == 'DYN_CONST' && lines[2] == '' &&
         lines[3].split.include?('add') && !lines[3].include?('gst')
    if ok
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  names=#{names.inspect} out=#{out.inspect}"
      @failed += 1
    end
  end

  # OKAMI-182: same for fish (`complete -C`); skipped without fish.
  def test_fish_completes_existing_entries
    print "Test 12: fish completes existing aliases... "
    unless system('command -v fish >/dev/null 2>&1')
      puts "skipped (no fish)"
      return
    end
    script, = run_wayu("completions fish")
    file = "#{@tmp_home}/wayu.fish"
    File.write(file, script)
    env = ENV.to_h.merge('HOME' => @tmp_home, 'PATH' => "#{File.dirname(@wayu_bin)}:#{ENV['PATH']}")
    probe = "source #{file}; complete -C 'wayu alias rm '; echo ---; complete -C 'wayu alias rm gst '"
    out, _err, st = Open3.capture3(env, 'fish', '--no-config', '-c', probe)
    first, second = out.split("---\n", 2)
    ok = st.success? && first.lines.map { |l| l.split("\t").first.chomp }.include?('gst') &&
         !first.include?('Add an alias') && !second.to_s.include?('gst')
    if ok
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  out=#{out.inspect}"
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
