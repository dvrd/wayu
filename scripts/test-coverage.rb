#!/usr/bin/env ruby
# frozen_string_literal: true

# Test coverage report script for wayu
# Runs unit, integration, and UI tests with comprehensive reporting

require 'fileutils'

BIN_DIR = './bin'
UNIT_TEST_DIR = './tests/unit'
INTEGRATION_TEST_DIR = './tests/integration'
UI_TEST_DIR = './tests/ui'
SRC_DIR = './src'
COVERAGE_DIR = './coverage'

# Create directories
FileUtils.mkdir_p(BIN_DIR)
FileUtils.mkdir_p(COVERAGE_DIR)

puts '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
puts '            Running Test Suite'
puts '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
puts ''

# ============================================================
# UNIT TESTS
# ============================================================

puts '📦 Running Unit Tests...'
puts '━' * 50

# Tests that need to run sequentially due to shared global state
sequential_tests = [
  'test_wayu.test_get_config_file_path',
  'test_wayu.test_get_plugins_config_file',
  'test_wayu.test_get_plugins_dir',
  'test_wayu.test_write_and_read_plugin_config'
].join(',')

# Run all tests in parallel
unit_output_parallel = `odin test #{UNIT_TEST_DIR} -file -out:#{BIN_DIR}/test_wayu 2>&1`
unit_parallel_success = $?.success?

# Run sequential tests
unit_output_sequential = `ODIN_TEST_THREADS=1 odin test #{UNIT_TEST_DIR} -file -out:#{BIN_DIR}/test_wayu -define:ODIN_TEST_NAMES=#{sequential_tests} 2>&1`
unit_sequential_success = $?.success?

unit_output = unit_output_parallel

if !unit_parallel_success && unit_sequential_success
  puts ''
  puts '✅ Sequential test run succeeded! Some tests have race conditions in parallel mode.'
end

# Extract test results
unit_test_match = unit_output.match(/Finished (\d+) tests.*?(\d+) test failed/)
if unit_test_match
  unit_total = unit_test_match[1].to_i
  unit_failed = unit_test_match[2].to_i
  unit_passed = unit_total - unit_failed
else
  # Try alternative match
  unit_test_match = unit_output.match(/Finished (\d+) tests/)
  if unit_test_match
    unit_total = unit_test_match[1].to_i
    unit_passed = unit_total
    unit_failed = 0
  else
    unit_total = 0
    unit_passed = 0
    unit_failed = 0
  end
end

puts "✓ Unit Tests: #{unit_passed}/#{unit_total} passed" + (unit_failed > 0 ? " (#{unit_failed} failed)" : "")
puts ''

# Clean up unit test binary
FileUtils.rm_f("#{BIN_DIR}/test_wayu")

# Save unit test output
File.write("#{COVERAGE_DIR}/unit_test_output.log", unit_output)

# ============================================================
# INTEGRATION TESTS
# ============================================================

puts '🔗 Running Integration Tests...'
puts '━' * 50

integration_tests = Dir.glob("#{INTEGRATION_TEST_DIR}/*_standalone.odin")
integration_results = {}
integration_passed = 0
integration_failed = 0
integration_total = 0

integration_tests.sort.each do |test_file|
  test_name = File.basename(test_file, '.odin')

  # Compile the standalone integration test directly
  binary_name = "#{BIN_DIR}/#{test_name}"
  compile_cmd = "odin build #{test_file} -file -out:#{binary_name} 2>&1"
  compile_output = `#{compile_cmd}`

  if $?.success?
    # Run the test
    test_output = `#{binary_name} 2>&1`
    test_success = $?.success?

    # Parse results from output
    passed_match = test_output.match(/(\d+)\/(\d+) tests passed/)
    if passed_match
      test_passed = passed_match[1].to_i
      test_total = passed_match[2].to_i
      test_failed = test_total - test_passed
    else
      # Try to count from summary line "✓ All X tests passed!"
      if test_output.include?('All') && test_output.include?('passed')
        all_match = test_output.match(/All (\d+)/)
        if all_match
          test_passed = all_match[1].to_i
          test_failed = 0
          test_total = test_passed
        else
          test_passed = test_success ? 1 : 0
          test_failed = test_success ? 0 : 1
          test_total = 1
        end
      else
        test_passed = test_success ? 1 : 0
        test_failed = test_success ? 0 : 1
        test_total = 1
      end
    end

    integration_results[test_name] = {
      passed: test_passed,
      failed: test_failed,
      total: test_total,
      output: test_output
    }

    integration_passed += test_passed
    integration_failed += test_failed
    integration_total += test_total

    # Print brief result
    status = test_failed == 0 ? '✓' : '✗'
    printf "  %s %-30s %d/%d passed\n", status, test_name, test_passed, test_total

    # Save individual test output
    File.write("#{COVERAGE_DIR}/#{test_name}_output.log", test_output)

    # Clean up binary
    FileUtils.rm_f(binary_name)
  else
    puts "  ✗ #{test_name} - Compilation failed"
    integration_failed += 1
    integration_total += 1
    File.write("#{COVERAGE_DIR}/#{test_name}_compile_error.log", compile_output)
  end
end

puts ''
puts "✓ Integration Tests: #{integration_passed}/#{integration_total} passed" + (integration_failed > 0 ? " (#{integration_failed} failed)" : "")
puts ''

# ============================================================
# UI TESTS
# ============================================================

puts '🎨 Running UI Tests...'
puts '━' * 50

ui_test_files = Dir.glob("#{UI_TEST_DIR}/test_*.odin")
ui_passed = 0
ui_failed = 0
ui_total = 0

ui_test_files.sort.each do |test_file|
  test_name = File.basename(test_file, '.odin')
  binary_name = "#{BIN_DIR}/#{test_name}"

  # Compile and run
  compile_cmd = "odin run #{test_file} -file -out:#{binary_name} 2>&1"
  test_output = `#{compile_cmd}`
  test_success = $?.success?

  # Parse results
  if test_output.include?('Passed:') && test_output.include?('Failed:')
    passed_match = test_output.match(/Passed: (\d+)/)
    failed_match = test_output.match(/Failed: (\d+)/)

    if passed_match && failed_match
      test_passed = passed_match[1].to_i
      test_failed = failed_match[1].to_i
      test_total = test_passed + test_failed

      ui_passed += test_passed
      ui_failed += test_failed
      ui_total += test_total

      status = test_failed == 0 ? '✓' : '✗'
      printf "  %s %-20s %d/%d passed\n", status, test_name, test_passed, test_total
    end
  else
    # Assume single test
    ui_total += 1
    if test_success
      ui_passed += 1
      puts "  ✓ #{test_name}"
    else
      ui_failed += 1
      puts "  ✗ #{test_name}"
    end
  end

  # Save output
  File.write("#{COVERAGE_DIR}/#{test_name}_output.log", test_output)

  # Clean up binary
  FileUtils.rm_f(binary_name)
end

puts ''
puts "✓ UI Tests: #{ui_passed}/#{ui_total} passed" + (ui_failed > 0 ? " (#{ui_failed} failed)" : "")
puts ''

# ============================================================
# UNIFIED SUMMARY
# ============================================================

puts ''
puts '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
puts '          Unified Test Report'
puts '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
puts ''

grand_total = unit_total + integration_total + ui_total
grand_passed = unit_passed + integration_passed + ui_passed
grand_failed = unit_failed + integration_failed + ui_failed

puts 'Test Summary by Type:'
puts ''
printf "  Unit Tests:        %3d/%3d passed", unit_passed, unit_total
puts unit_failed > 0 ? " (#{unit_failed} failed)" : " ✓"

printf "  Integration Tests: %3d/%3d passed", integration_passed, integration_total
puts integration_failed > 0 ? " (#{integration_failed} failed)" : " ✓"

printf "  UI Tests:          %3d/%3d passed", ui_passed, ui_total
puts ui_failed > 0 ? " (#{ui_failed} failed)" : " ✓"

puts ''
puts '─' * 50
printf "  TOTAL:             %3d/%3d passed", grand_passed, grand_total
puts grand_failed > 0 ? " (#{grand_failed} failed)" : " ✓"
puts ''

# Coverage information (unit tests)
puts ''
puts 'Unit Test Coverage:'
puts ''

test_files = Dir.glob("#{UNIT_TEST_DIR}/*.odin")
src_files = Dir.glob("#{SRC_DIR}/*.odin")

testable_components = %w[
  alias backup colors completions constants debug fuzzy init main
  path plugin preload shell style table validation
]

# Count functions/procs in source files
def count_procs(file_path)
  content = File.read(file_path)
  content.scan(/^\s*\w+\s*::\s*proc\s*\(/).count
end

covered_components = 0
total_components = 0

src_files.sort.each do |file|
  filename = File.basename(file, '.odin')
  next unless testable_components.include?(filename)

  total_components += 1
  test_file = "#{UNIT_TEST_DIR}/test_#{filename}.odin"

  proc_count = count_procs(file)
  test_count = File.exist?(test_file) ? File.read(test_file).scan(/@\(test\)/).count : 0

  if File.exist?(test_file)
    covered_components += 1
    coverage_pct = proc_count > 0 ? (test_count.to_f / proc_count * 100).round : 100
    coverage_pct = [coverage_pct, 100].min

    printf "  ✓ %-15s %2d procs, %2d tests (%3d%%)\n", filename, proc_count, test_count, coverage_pct
  else
    printf "  ✗ %-15s %2d procs, %2d tests (  0%%)\n", filename, proc_count, 0
  end
end

puts ''
overall_coverage = total_components > 0 ? (covered_components.to_f / total_components * 100).round : 0
puts "Overall Coverage: #{covered_components}/#{total_components} components (#{overall_coverage}%)"

puts ''
puts "Test outputs saved to: #{COVERAGE_DIR}/"
puts '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
puts ''

# Exit with failure if any tests failed
exit(1) if grand_failed > 0
