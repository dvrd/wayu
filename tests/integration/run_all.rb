#!/usr/bin/env ruby
# Master test runner for all integration tests

require 'open3'

class IntegrationTestRunner
  def initialize
    @test_files = Dir.glob(File.join(__dir__, 'test_*.rb'))
    @results = {}
  end

  def run
    puts "🚀 Running all integration tests..."
    puts "=" * 60
    puts

    @test_files.each do |test_file|
      run_test(test_file)
      puts
    end

    print_summary
  end

  private

  def run_test(test_file)
    test_name = File.basename(test_file, '.rb').gsub('test_', '').capitalize
    puts "Running #{test_name} Tests"
    puts "-" * 40

    stdout, stderr, status = Open3.capture3("ruby #{test_file}")

    # Print the output as-is
    puts stdout
    puts stderr unless stderr.empty?

    # Store result
    @results[test_name] = status.success?

    if status.success?
      puts "✅ #{test_name} tests completed successfully"
    else
      puts "❌ #{test_name} tests failed"
    end
  end

  def print_summary
    puts "=" * 60
    puts "INTEGRATION TEST SUMMARY"
    puts "=" * 60

    passed = @results.values.count(true)
    failed = @results.values.count(false)
    total = @results.size

    @results.each do |name, success|
      status = success ? "✅ PASS" : "❌ FAIL"
      puts "  #{status} - #{name}"
    end

    puts
    puts "Total: #{passed}/#{total} test suites passed"

    if failed > 0
      puts "⚠️  #{failed} test suite(s) failed"
      exit 1
    else
      puts "🎉 All integration tests passed!"
      exit 0
    end
  end
end

# Run if executed directly
if __FILE__ == $0
  IntegrationTestRunner.new.run
end