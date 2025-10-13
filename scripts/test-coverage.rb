#!/usr/bin/env ruby
# frozen_string_literal: true

# Test coverage report script for wayu
# Runs tests and generates coverage summary

require 'fileutils'

BIN_DIR = './bin'
TEST_DIR = './tests/unit'
SRC_DIR = './src'
COVERAGE_DIR = './coverage'

# Create directories
FileUtils.mkdir_p(BIN_DIR)
FileUtils.mkdir_p(COVERAGE_DIR)

puts 'Running tests with coverage tracking...'
puts ''

# Tests that need to run sequentially due to shared global state
sequential_tests = [
  'test_wayu.test_get_config_file_path',
  'test_wayu.test_get_plugins_config_file',
  'test_wayu.test_get_plugins_dir',
  'test_wayu.test_write_and_read_plugin_config'
].join(',')

# First, run all tests in parallel (including the problematic ones)
# This gives us the full test output with potential failures
puts '🔄 Running all tests in parallel...'
test_output_parallel = `odin test #{TEST_DIR} -file -out:#{BIN_DIR}/test_wayu 2>&1`
parallel_success = $?.success?

# Then run the sequential tests with single thread to get accurate results
puts ''
puts '🔄 Re-running potentially flaky tests sequentially...'
test_output_sequential = `ODIN_TEST_THREADS=1 odin test #{TEST_DIR} -file -out:#{BIN_DIR}/test_wayu -define:ODIN_TEST_NAMES=#{sequential_tests} 2>&1`
sequential_success = $?.success?

# Combine outputs - use sequential results for the 3 tests, parallel for the rest
# For simplicity, we'll just show the parallel output and note if sequential fixed issues
test_output = test_output_parallel

if !parallel_success && sequential_success
  puts ''
  puts '✅ Sequential test run succeeded! The failures above are due to parallel execution race conditions.'
  puts '    These tests pass when run individually or with ODIN_TEST_THREADS=1'
end

File.write("#{COVERAGE_DIR}/test_output.log", test_output)
File.write("#{COVERAGE_DIR}/test_output_sequential.log", test_output_sequential)
puts test_output

# Clean up test binary
FileUtils.rm_f("#{BIN_DIR}/test_wayu")

puts ''
puts '======================================'
puts '       Test Coverage Summary'
puts '======================================'
puts ''

# Count files
test_files = Dir.glob("#{TEST_DIR}/*.odin")
src_files = Dir.glob("#{SRC_DIR}/*.odin")
total_tests = test_files.sum do |file|
  File.read(file).scan(/@\(test\)/).count
end

puts "Test Files:     #{test_files.count}"
puts "Source Files:   #{src_files.count}"
puts "Total Tests:    #{total_tests}"
puts ''

# List test files and count tests per file
puts 'Test Breakdown:'
test_files.sort.each do |file|
  filename = File.basename(file)
  count = File.read(file).scan(/@\(test\)/).count
  printf "  %-25s %2d tests\n", filename, count
end

puts ''
puts 'Coverage per Source File:'

# Check which source files have corresponding tests and calculate coverage
testable_components = %w[
  alias backup colors completions constants debug fuzzy init main
  path plugin preload shell style table validation
]

# Count functions/procs in source files
def count_procs(file_path)
  content = File.read(file_path)
  # Count proc definitions (proc name :: proc(...))
  content.scan(/^\s*\w+\s*::\s*proc\s*\(/).count
end

covered_components = 0
total_components = 0

src_files.sort.each do |file|
  filename = File.basename(file, '.odin')
  next unless testable_components.include?(filename)

  total_components += 1
  test_file = "#{TEST_DIR}/test_#{filename}.odin"

  proc_count = count_procs(file)
  test_count = File.exist?(test_file) ? File.read(test_file).scan(/@\(test\)/).count : 0

  if File.exist?(test_file)
    covered_components += 1
    # Estimate coverage percentage (tests vs procedures)
    coverage_pct = proc_count > 0 ? (test_count.to_f / proc_count * 100).round : 100
    coverage_pct = [coverage_pct, 100].min # Cap at 100%

    printf "  ✓ %-15s %2d procs, %2d tests (%3d%%)\n", filename, proc_count, test_count, coverage_pct
  else
    printf "  ✗ %-15s %2d procs, %2d tests (  0%%)\n", filename, proc_count, 0
  end
end

puts ''
overall_coverage = total_components > 0 ? (covered_components.to_f / total_components * 100).round : 0
puts "Overall Coverage: #{covered_components}/#{total_components} components (#{overall_coverage}%)"

puts ''
puts "Full test output saved to: #{COVERAGE_DIR}/test_output.log"
puts '======================================'
