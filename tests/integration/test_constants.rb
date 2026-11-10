#!/usr/bin/env ruby
# Integration tests for constants command

require 'open3'
require 'fileutils'
require_relative 'test_helper'

class ConstantsIntegrationTest
  include WayuTestHelper

  def initialize
    setup_test_env
  end

  def run
    puts "🔢 Testing constants command integration..."
    puts

    begin
      build_project
      initialize_wayu

      test_add_simple_constant
      test_add_constant_with_spaces
      test_add_constant_with_special_chars
      test_list_constants
      test_get_constant
      test_get_constant_not_found
      test_get_constant_empty_name
      test_get_constant_unescapes_value
      test_remove_constant
      test_duplicate_constant_handling
      test_constant_name_validation
      test_lowercase_constant_warning
      test_constant_value_with_quotes
      test_constant_with_numbers
      test_multiline_value_handling
      test_constant_persistence
      test_list_constants_from_wayu_toml_env
      test_full_list_names_each_env_var_once
      test_get_constant_from_wayu_toml_constants
      test_add_constant_to_wayu_toml
      test_remove_constant_from_wayu_toml
      test_help_command
      test_const_alias
      test_utf8_and_empty_values_survive_rewrite
      test_protected_names_refused
      test_invalid_utf8_value_is_data_error
    ensure
      teardown_test_env
    end

    print_summary("constants")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def report(ok, detail)
    if ok
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  #{detail}"
      @failed += 1
    end
  end

  # Regression (OKAMI-304): `const add PATH /x` was accepted and broke every
  # new shell. Protected names exit 65; stored ones are a doctor error.
  def test_protected_names_refused
    print "Test R2: Protected names (PATH, HOME, IFS, WAYU_*) exit 65; doctor flags stored ones... "

    codes = %w[PATH HOME IFS SHELL ZDOTDIR WAYU_CONFIG_DIR WAYU_ANY].map do |n|
      run_wayu("const add #{n} /x")[1].exitstatus
    end
    _, secret = run_wayu("const add PATH /x --secret")
    stored_before = store_map('env')
    write_entries(env: stored_before.merge('PATH' => '/x'))
    doc_out, doc = run_wayu('doctor')
    _, rm = run_wayu('const rm PATH')
    report(codes.all?(65) && secret.exitstatus == 65 && !stored_before.key?('PATH') &&
           doc.exitstatus == 78 && doc_out.include?('protected environment names') &&
           doc_out.include?('PATH') && rm.success?,
           "codes=#{codes} secret=#{secret.exitstatus} doctor=#{doc.exitstatus} rm=#{rm.exitstatus}\n#{doc_out}")
  end

  # Regression (OKAMI-331): a value that is not UTF-8 printed two errors and
  # exited 74 (I/O) instead of one data error.
  def test_invalid_utf8_value_is_data_error
    print "Test R3: A non-UTF-8 value is one data error (65)... "

    out, st = run_wayu(%q(const add BADUTF "$(printf 'a\377b')"))
    errors = out.lines.count { |l| l.include?('ERROR') }
    report(st.exitstatus == 65 && errors == 1 && out.include?('UTF-8') && !store_map('env').key?('BADUTF'),
           "status=#{st.exitstatus} out=#{out}")
  end

  # Regressions: unescape mangled UTF-8 (é → Ã©); an empty value was
  # dropped by the reader and so deleted on the next write.
  def test_utf8_and_empty_values_survive_rewrite
    print "Test R1: UTF-8 and empty values survive a rewrite... "

    write_entries(env: store_map('env').merge('EMPTY_C' => '', 'CMT_C' => 'nvim # not a comment'))
    run_wayu("const add CAFE_C 'café'")
    out_cafe, s1 = run_wayu("const get CAFE_C")
    out_cmt, _ = run_wayu("const get CMT_C")
    env = store_map('env')

    ok = s1.success? && out_cafe.strip == "café" && out_cmt.strip == "nvim # not a comment" &&
         env['EMPTY_C'] == '' && env['CAFE_C'] == 'café'
    if ok
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  cafe=#{out_cafe} cmt=#{out_cmt}\n  env=#{env}"
      @failed += 1
    end
  end

  def test_add_simple_constant
    print "Test 1: Add simple constant... "

    output, status = run_wayu('constants add MY_VAR "test_value"')

    if status.success? && store_map('env')['MY_VAR'] == 'test_value'
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to add simple constant"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_add_constant_with_spaces
    print "Test 2: Add constant with spaces in value... "

    output, status = run_wayu('constants add MY_PATH "/usr/local/my path"')

    if status.success? && store_map('env')['MY_PATH'] == '/usr/local/my path'
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to add constant with spaces"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_add_constant_with_special_chars
    print "Test 3: Add constant with special characters... "

    output, status = run_wayu('constants add API_KEY "abc-123_xyz.789"')

    if status.success? && store_map('env')['API_KEY'] == 'abc-123_xyz.789'
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to add constant with special chars"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_list_constants
    print "Test 4: List all constants... "

    output, status = run_wayu("constants list")

    # Should show our test constants
    if status.success? && output.include?("MY_VAR")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  List command failed or missing constants"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_get_constant
    print "Test 5a: Get constant value (happy path)... "

    run_wayu('constants add GET_TEST "hello_world"')
    output, status = run_wayu("constants get GET_TEST")

    if status.success? && output.strip == "hello_world"
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected 'hello_world', got '#{output.strip}'"
      puts "  Exit status: #{status.exitstatus}"
      @failed += 1
    end
  end

  def test_get_constant_not_found
    print "Test 5b: Get non-existent constant returns error... "

    output, status = run_wayu("constants get NONEXISTENT_XYZ_123")

    if !status.success? && status.exitstatus == 65
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected exit 65, got #{status.exitstatus}"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_get_constant_empty_name
    print "Test 5c: Get with empty name returns usage error... "

    output, status = run_wayu('constants get ""')

    if !status.success? && status.exitstatus == 64
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected exit 64 (usage), got #{status.exitstatus}"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_get_constant_unescapes_value
    print "Test 5d: Get unescapes shell-escaped values... "

    # A value with double quotes round-trips through entries.json unchanged
    run_wayu('constants add ESCAPE_TEST \'say "hello"\'')
    output, status = run_wayu("constants get ESCAPE_TEST")
    run_wayu("constants rm ESCAPE_TEST")

    expected = 'say "hello"'
    if status.success? && output.strip == expected
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected: #{expected.inspect}"
      puts "  Got:      #{output.strip.inspect}"
      @failed += 1
    end
  end

  def test_remove_constant
    print "Test 5: Remove constant... "

    output, status = run_wayu("constants rm MY_VAR")

    if status.success? && !store_map('env').key?('MY_VAR')
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to remove constant"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_duplicate_constant_handling
    print "Test 6: Duplicate constant handling... "

    # Add constant twice
    run_wayu('constants add DUPLICATE_TEST "first"')
    output, status = run_wayu('constants add DUPLICATE_TEST "second"')

    # Should either prevent duplicate or overwrite
    occurrences = (read_entries['env'] || []).count { |e| e['name'] == 'DUPLICATE_TEST' }

    if occurrences == 1 && store_map('env')['DUPLICATE_TEST'] == 'second'
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Duplicate constants allowed (found #{occurrences} occurrences)"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_constant_name_validation
    print "Test 7: Constant name validation... "

    # Try invalid names
    output1, status1 = run_wayu('constants add "bad-name" "value"')
    output2, status2 = run_wayu('constants add "123ABC" "value"')
    output3, status3 = run_wayu('constants add "while" "value"')

    # All should fail with validation errors
    invalid1 = !status1.success? && (output1.include?("invalid") || output1.include?("Invalid"))
    invalid2 = !status2.success? && output2.include?("must start with")
    invalid3 = !status3.success? && output3.include?("reserved")

    if invalid1 && invalid2 && invalid3
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Validation not working correctly"
      puts "  Dash test: #{invalid1}, Digit test: #{invalid2}, Reserved test: #{invalid3}"
      @failed += 1
    end
  end

  def test_lowercase_constant_warning
    print "Test 8: Lowercase constant warning... "

    output, status = run_wayu('constants add my_lowercase_var "value"')

    # A warning, not an error: it is stored, and the message names the rule.
    if status.success? && output.include?("contains lowercase letters") &&
       output.include?("UPPER_CASE") && store_map('env')['my_lowercase_var'] == 'value'
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Should warn about lowercase in constant name"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_constant_value_with_quotes
    print "Test 9: Constant value with quotes... "

    output, status = run_wayu('constants add QUOTED_VALUE "\"Hello, World!\""')

    if status.success? && store_map('env')['QUOTED_VALUE'] == '"Hello, World!"'
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to handle quotes in value"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_constant_with_numbers
    print "Test 10: Constant with numbers... "

    output, status = run_wayu('constants add VERSION_2024 "1.2.3"')

    if status.success? && store_map('env')['VERSION_2024'] == '1.2.3'
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to add constant with numbers"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_multiline_value_handling
    print "Test 11: Value with newline characters... "

    # Try to add value with \n (should handle gracefully)
    output, status = run_wayu('constants add MULTILINE "line1\nline2"')

    # Should either succeed with proper escaping or show error
    if status.success? || output.include?("invalid") || output.include?("newline")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Unexpected handling of newlines"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_constant_persistence
    print "Test 12: Constant persistence after modifications... "

    # Add a constant
    run_wayu('constants add PERSIST_TEST_1 "value1"')

    # Add another constant
    run_wayu('constants add PERSIST_TEST_2 "value2"')
    env = store_map('env')

    # Both should exist
    if env['PERSIST_TEST_1'] == 'value1' && env['PERSIST_TEST_2'] == 'value2'
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Constants not persisted correctly"
      @failed += 1
    end
  end

  def test_list_constants_from_wayu_toml_env
    print "Test 16: List constants from entries.json... "

    write_entries(env: { 'FROM_TOML' => 'loaded', 'SECOND_VAR' => 'also_loaded' })

    output, status = run_wayu("constants list")

    if status.success? && output.include?("FROM_TOML") && output.include?("loaded")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected constants list to read from entries.json"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_get_constant_from_wayu_toml_constants
    print "Test 17: Get constant from entries.json... "

    write_entries(env: { 'TOML_ONLY' => 'from_table' })

    output, status = run_wayu("constants get TOML_ONLY")

    if status.success? && output.strip == "from_table"
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected 'from_table', got '#{output.strip}'"
      @failed += 1
    end
  end

  def test_add_constant_to_wayu_toml
    print "Test 18: Add constant writes to entries.json only... "

    write_entries(env: { 'EXISTING' => 'value' })
    toml_before = File.read("#{@config_dir}/wayu.toml")

    output, status = run_wayu('constants add TOML_ADDED "new_value"')
    env = (read_entries['env'] || []).map { |e| [e['name'], e['value']] }

    if status.success? && env == [%w[EXISTING value], %w[TOML_ADDED new_value]] &&
       File.read("#{@config_dir}/wayu.toml") == toml_before
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected constants add to append to entries.json and leave wayu.toml alone"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_remove_constant_from_wayu_toml
    print "Test 19: Remove constant writes to entries.json... "

    write_entries(env: { 'REMOVE_ME' => 'bye', 'KEEP_ME' => 'stay' })

    output, status = run_wayu('constants rm REMOVE_ME')
    env = store_map('env')

    if status.success? && !env.key?('REMOVE_ME') && env['KEEP_ME'] == 'stay'
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected constants rm to update entries.json"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_help_command
    print "Test 13: Help command... "

    output, status = run_wayu("constants help")

    if output.include?("EXAMPLES") && output.include?("wayu const add")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Help output incomplete"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_const_alias
    print "Test 14: 'const' alias behaves identically to 'constants'... "

    write_entries(env: { 'BASE' => 'value' })

    run_wayu('const add CONST_ALIAS_TEST "alias_value"')
    added = store_map('env')['CONST_ALIAS_TEST'] == 'alias_value'

    list_out, list_status = run_wayu("const list")
    listed = list_status.success? && list_out.include?("CONST_ALIAS_TEST")

    get_out, get_status = run_wayu("const get CONST_ALIAS_TEST")
    got = get_status.success? && get_out.strip == "alias_value"

    run_wayu("const rm CONST_ALIAS_TEST")
    removed = !store_map('env').key?('CONST_ALIAS_TEST')

    if added && listed && got && removed
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  const alias failed (add=#{added}, list=#{listed}, get=#{got}, rm=#{removed})"
      @failed += 1
    end
  end

  def test_full_list_names_each_env_var_once
    print "  Testing const list --full lists each env var once... "
    # Minimal, controlled environment: Odin's os.environ repeats environ[0].
    env = { 'HOME' => @tmp_home, 'PATH' => ENV['PATH'], 'WAYU_FIRST_VAR' => 'x', 'NO_COLOR' => '1' }.merge(sanitizer_env)
    out, _err, status = Open3.capture3(env, "#{@wayu_bin} --json const list --full", unsetenv_others: true)
    names = out.scan(/"constant": "([^"]+)"/).flatten
    dups = names.select { |n| names.count(n) > 1 }.uniq
    if status.success? && !names.empty? && dups.empty?
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  duplicates: #{dups.inspect} (exit #{status.exitstatus})"
      @failed += 1
    end
  end

end

# Run tests if executed directly
if __FILE__ == $0
  ConstantsIntegrationTest.new.run
end
