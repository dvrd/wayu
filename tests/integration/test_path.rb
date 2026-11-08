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
      test_relative_path_removal
      test_expanded_path_storage
      test_path_with_spaces
      test_symlink_handling
      test_nonexistent_path_handling
      test_remove_nonexistent_path
      test_path_persistence_after_modifications
      test_clean_operates_on_wayu_toml
      test_dedup_operates_on_wayu_toml
      test_add_detects_resolved_duplicate
      test_clean_keeps_unresolved_and_env_paths
      test_dedup_refuses_duplicate_key
      test_remove_by_key_hook_gets_path
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

    test_dir = "#{@scratch}/wayu_test_path1"
    Dir.mkdir(test_dir) unless Dir.exist?(test_dir)

    output, status = run_wayu("path add #{test_dir}")

    if status.success? && File.read(@toml_file).include?("= \"#{test_dir}\"")
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

    test_dirs = ["#{@scratch}/wayu_test_path2", "#{@scratch}/wayu_test_path3", "#{@scratch}/wayu_test_path4"]
    test_dirs.each { |dir| Dir.mkdir(dir) unless Dir.exist?(dir) }

    test_dirs.each { |dir| run_wayu("path add #{dir}") }

    path_content = File.read(@toml_file)
    all_present = test_dirs.all? { |dir| path_content.include?("= \"#{dir}\"") }

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
    if status.success? && output.include?("#{@scratch}/wayu_test_path")
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

    test_dir = "#{@scratch}/wayu_test_path1"
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

  # Replace the [paths] table of wayu.toml with raw `key = "value"` lines.
  def write_paths_table(lines)
    content = File.read(@toml_file).sub(/^\[paths\][^\[]*/m, "")
    File.write(@toml_file, content.rstrip + "\n\n[paths]\n" + lines.join("\n") + "\n")
  end

  # Regression: clean/dedup used to edit the legacy path.zsh, never wayu.toml.
  def test_clean_operates_on_wayu_toml
    print "Test 13: path clean removes missing entries from wayu.toml... "

    keep = "#{@scratch}/wayu_test_clean_keep"
    FileUtils.mkdir_p(keep)
    write_paths_table([%(keep = "#{keep}"), %(gone = "#{@scratch}/wayu_test_clean_gone_#{$$}"), %(home_var = "$HOME")])

    dry_out, dry_status = run_wayu("--dry-run path clean")
    after_dry = File.read(@toml_file)
    refuse_out, refuse_status = run_wayu("path clean")
    output, status = run_wayu("path clean --yes")
    content = File.read(@toml_file)

    report(dry_status.success? && dry_out.include?("gone") && after_dry.include?("gone =") &&
           refuse_status.exitstatus == 64 &&
           status.success? && !content.include?("gone =") && content.include?("keep =") &&
           content.include?("home_var ="),  # $HOME expands → exists → kept
           "dry=#{dry_out}\nrefuse=#{refuse_out}\nout=#{output}\ntoml=#{content}")
  end

  def test_dedup_operates_on_wayu_toml
    print "Test 14: path dedup removes resolved duplicates from wayu.toml... "

    write_paths_table([%(a_home = "$HOME"), %(b_home = "#{@tmp_home}"), %(c_tmp = "/tmp")])
    output, status = run_wayu("path dedup --yes")
    content = File.read(@toml_file)

    report(status.success? && content.include?("a_home =") && !content.include?("b_home =") &&
           content.include?("c_tmp ="),
           "out=#{output}\ntoml=#{content}")
  end

  # Regression: `$HOME/x` stored + `add ~/x` (or the absolute form) was not
  # detected as a duplicate because only the new side was expanded.
  def test_add_detects_resolved_duplicate
    print "Test 15: add detects duplicate of an env-var path... "

    write_paths_table([%(home = "$HOME")])
    output, status = run_wayu("path add #{@tmp_home}")
    content = File.read(@toml_file)

    report(status.success? && output.include?("already") && !output.include?("Added") &&
           content.scan("#{@tmp_home}").empty?,
           "out=#{output}\ntoml=#{content}")
  end

  # Regression (OKAMI-168): clean deleted entries using a variable it could
  # not resolve, and ignored wayu.toml [env] (core exports it before PATH).
  def test_clean_keeps_unresolved_and_env_paths
    print "Test 16: path clean keeps $VAR entries it cannot prove missing... "

    tools = "#{@tmp_home}/okami168_tools"
    FileUtils.mkdir_p("#{tools}/bin")
    run_wayu("const add OKAMI168_ROOT #{tools}")
    write_paths_table([%(unset_bin = "$WAYU_OKAMI168_SURELY_UNSET/bin"),
                       %(env_bin = "${OKAMI168_ROOT}/bin"),
                       %(gone = "#{@scratch}/wayu_test_clean168_gone_#{$$}")])
    output, status = run_wayu("path clean --yes")
    content = File.read(@toml_file)

    report(status.success? && content.include?("unset_bin =") && content.include?("env_bin =") &&
           !content.include?("gone ="),
           "out=#{output}\ntoml=#{content}")
  end

  # Regression (OKAMI-168): two entries sharing a (hand-edited) key — dedup
  # deleted every line of that key, dropping the survivor too.
  def test_dedup_refuses_duplicate_key
    print "Test 17: path dedup refuses a duplicate [paths] key... "

    write_paths_table([%(dup = "/tmp"), %(dup = "/tmp")])
    before = File.read(@toml_file)
    output, status = run_wayu("path dedup --yes")
    after = File.read(@toml_file)

    report(status.exitstatus == 78 && before == after && output.include?("Duplicate key"),
           "status=#{status.exitstatus}\nout=#{output}\ntoml=#{after}")
  end

  # Regression (OKAMI-168): `path rm <key>` passed the key, not the
  # directory, as {path} to pre/post_path_remove.
  def test_remove_by_key_hook_gets_path
    print "Test 18: path rm <key> gives hooks the directory... "

    log = "#{@tmp_home}/okami168_hook.log"
    hooks = "#{@config_dir}/hooks.conf"
    File.write(hooks, "pre_path_remove = echo pre:{path} >> #{log}\n" \
                      "post_path_remove = echo post:{path} >> #{log}\n")
    write_paths_table([%(hooked = "/tmp")])
    output, status = run_wayu("path rm hooked")
    logged = File.exist?(log) ? File.read(log) : ""
    FileUtils.rm_f(hooks)

    report(status.success? && logged == "pre:/tmp\npost:/tmp\n",
           "out=#{output}\nlog=#{logged.inspect}")
  end

  def test_duplicate_path_handling
    print "Test 5: Duplicate path handling... "

    test_dir = "#{@scratch}/wayu_test_duplicate"
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

    # Insertion order deliberately differs from alphabetical order: [paths]
    # order is PATH precedence, so wayu must never re-sort it (OKAMI-201).
    test_dirs = ["#{@scratch}/wayu_order_zeta", "#{@scratch}/wayu_order_alpha", "#{@scratch}/wayu_order_mid"]
    test_dirs.each { |dir| Dir.mkdir(dir) unless Dir.exist?(dir) }

    # Remove all test paths first
    Dir.glob("#{@scratch}/wayu_*").each { |dir| run_wayu("path rm #{dir}") }

    # Add in order
    test_dirs.each { |dir| run_wayu("path add #{dir}") }

    path_content = File.read(@toml_file)
    order1_pos = path_content.index("wayu_order_zeta")
    order2_pos = path_content.index("wayu_order_alpha")
    order3_pos = path_content.index("wayu_order_mid")

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

    project_root = File.expand_path('../..', __dir__)
    cases = {
      '.' => project_root,
      './bin' => "#{project_root}/bin",
      'bin/wayu' => "#{project_root}/bin/wayu",
      "../#{File.basename(project_root)}/tests" => "#{project_root}/tests",
      'relative_named=tests/integration' => "#{project_root}/tests/integration"
    }

    failures = cases.map do |argument, expected|
      output, status = run_wayu("path add #{argument}")
      content = File.read(@toml_file)
      stored = content.include?("= \"#{expected}\"")
      named = !argument.start_with?('relative_named=') ||
              content.include?("relative_named = \"#{expected}\"")
      "#{argument}: #{output}" unless status.success? && stored && named
    end

    failures.compact!

    if failures.empty?
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Relative paths were not stored as absolute paths:"
      failures.each { |failure| puts "  #{failure}" }
      @failed += 1
    end
  end

  def test_relative_path_removal
    print "Test: Remove relative paths like add resolves them... "

    project_root = File.expand_path('../..', __dir__)
    cases = {
      './bin' => "#{project_root}/bin",
      'bin/wayu' => "#{project_root}/bin/wayu",
      "../#{File.basename(project_root)}/tests" => "#{project_root}/tests"
    }

    failures = cases.map do |argument, expected|
      run_wayu("path add #{argument}")
      output, status = run_wayu("path rm #{argument}")
      still_there = File.read(@toml_file).include?("= \"#{expected}\"")
      "#{argument}: #{output}" unless status.success? && !still_there
    end

    failures.compact!

    if failures.empty?
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Relative paths were not removed:"
      failures.each { |failure| puts "  #{failure}" }
      @failed += 1
    end
  end

  def test_expanded_path_storage
    print "Test: Store expanded paths and deduplicate equivalent inputs... "
    FileUtils.mkdir_p("#{@tmp_home}/bin")
    FileUtils.mkdir_p("#{@tmp_home}/tools")
    cases = {
      "'$HOME/bin'" => "#{@tmp_home}/bin",
      "'${HOME}/tools'" => "#{@tmp_home}/tools",
      "'~/bin'" => "#{@tmp_home}/bin",
      "'home_named=~'" => @tmp_home
    }
    failures = cases.map do |argument, expected|
      output, status = run_wayu("path add #{argument}")
      content = File.read(@toml_file)
      "#{argument}: #{output}" unless status.success? &&
        content.include?("= \"#{expected}\"") &&
        !content.include?('$HOME') && !content.include?('${HOME}') &&
        !content.include?('"~')
    end.compact

    content = File.read(@toml_file)
    failures << 'Equivalent home paths were duplicated' unless
      content.scan("= \"#{@tmp_home}/bin\"").length == 1

    # An unresolved token must fail even if a directory with that literal name exists.
    FileUtils.mkdir_p("#{@tmp_home}/$WAYU_UNSET_PATH_TEST/bin")
    output, status = run_wayu("path add '#{@tmp_home}/$WAYU_UNSET_PATH_TEST/bin'")
    failures << "Unresolved variable was saved: #{output}" if
      status.success? || File.read(@toml_file) != content

    output, status = run_wayu("path add 'preview=$HOME/.config' --dry-run")
    failures << "Dry run did not resolve the path: #{output}" unless
      status.success? && output.include?("#{@tmp_home}/.config") &&
      File.read(@toml_file) == content

    if failures.empty?
      puts "✓"
      @passed += 1
    else
      puts "✗"
      failures.each { |failure| puts "  #{failure}" }
      @failed += 1
    end
  end

  def test_path_with_spaces
    print "Test 8: Path with spaces... "

    test_dir = "#{@scratch}/wayu test with spaces"
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

    real_dir = "#{@scratch}/wayu_real_dir"
    link_dir = "#{@scratch}/wayu_link_dir"

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

    if output.include?("not found") || output.include?("does not exist") || output.include?("Not found")
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
    test_dir = "#{@scratch}/wayu_persist_test"
    Dir.mkdir(test_dir) unless Dir.exist?(test_dir)
    run_wayu("path add #{test_dir}")

    # Read content
    content_before = File.read(@toml_file)

    # Add another path (triggers file write)
    test_dir2 = "#{@scratch}/wayu_persist_test2"
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
