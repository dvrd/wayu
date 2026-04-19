#!/usr/bin/env ruby
# Integration tests exercising the fish-specific code paths.
# Overrides SHELL=fish so wayu's DETECTED_SHELL resolves to .FISH.

require 'open3'
require 'fileutils'
require_relative 'test_helper'

class FishIntegrationTest
  include WayuTestHelper

  def initialize
    setup_test_env
    @toml_file = "#{@config_dir}/wayu.toml"
    @init_core = "#{@config_dir}/init-core.fish"
    @static    = "#{@config_dir}/wayu_static.fish"
  end

  def run
    puts "🐟 Testing fish shell integration..."
    puts

    begin
      build_project
      initialize_fish

      test_toml_shell_type_is_fish
      test_alias_writes_to_toml
      test_constant_writes_to_toml
      test_path_writes_to_toml
      test_init_core_fish_is_native_syntax
      test_watch_regenerate_emits_fish
    ensure
      teardown_test_env
    end

    print_summary("fish")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  # Override initialize_wayu from helper so we can force SHELL=fish.
  def initialize_fish
    print "Initializing wayu config for fish..."
    output, status = run_fish('init --shell fish')
    if status.success?
      puts " ✓"
    else
      puts " ✗"
      puts "Init failed: #{output}"
      teardown_test_env
      exit 1
    end
    puts
  end

  # Like run_wayu but forces SHELL=/usr/bin/fish so DETECTED_SHELL is FISH.
  def run_fish(args)
    env = ENV.to_h.merge('HOME' => @tmp_home, 'SHELL' => '/usr/bin/fish')
    project_root = File.expand_path('../..', __dir__)
    stdout, stderr, status = Open3.capture3(env, "#{@wayu_bin} #{args}", chdir: project_root)
    [stdout.force_encoding('UTF-8') + stderr.force_encoding('UTF-8'), status]
  end

  def test_toml_shell_type_is_fish
    print "Test 1: wayu.toml records type=\"Fish\"... "
    content = File.read(@toml_file)
    if content.include?('type = "Fish"')
      puts "✓"; @passed += 1
    else
      puts "✗"; puts "  TOML did not record Fish shell type"
      puts "  Content: #{content[0..200]}"; @failed += 1
    end
  end

  def test_alias_writes_to_toml
    print "Test 2: alias add writes to wayu.toml (fish)... "
    _, status = run_fish('alias add ll "ls -la"')
    content = File.read(@toml_file)
    if status.success? && content.include?('ll = "ls -la"')
      puts "✓"; @passed += 1
    else
      puts "✗"; puts "  Alias not written to wayu.toml under fish"; @failed += 1
    end
  end

  def test_constant_writes_to_toml
    print "Test 3: constants add writes to wayu.toml (fish)... "
    _, status = run_fish('constants add API_URL "https://example.com"')
    content = File.read(@toml_file)
    if status.success? && content.include?('API_URL = "https://example.com"')
      puts "✓"; @passed += 1
    else
      puts "✗"; puts "  Constant not written to wayu.toml under fish"; @failed += 1
    end
  end

  def test_path_writes_to_toml
    print "Test 4: path add writes to wayu.toml (fish)... "
    _, status = run_fish('path add /tmp')
    content = File.read(@toml_file)
    if status.success? && content.include?('path = "/tmp"')
      puts "✓"; @passed += 1
    else
      puts "✗"; puts "  Path not written to wayu.toml under fish"; @failed += 1
    end
  end

  def test_init_core_fish_is_native_syntax
    print "Test 5: init-core.fish uses fish-native syntax... "
    # Rebuild after alias/path were added so init-core.fish reflects them.
    run_fish('build eval')
    unless File.exist?(@init_core)
      puts "✗"; puts "  init-core.fish not created"; @failed += 1
      return
    end
    body = File.read(@init_core)
    fish_ok = body.include?('#!/usr/bin/env fish') &&
              body.include?('set -gx PATH') &&
              body.include?("alias ll 'ls -la'")
    bash_leak = body.include?('export PATH=') || body.include?('typeset -U') ||
                body.include?('zsh-defer') || body.include?('autoload')
    if fish_ok && !bash_leak
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  fish_ok=#{fish_ok} bash_leak=#{bash_leak}"
      @failed += 1
    end
  end

  def test_watch_regenerate_emits_fish
    print "Test 6: watch regenerate emits fish wayu_static.fish... "
    _, status = run_fish('watch regenerate')
    unless status.success? && File.exist?(@static)
      puts "✗"; puts "  regenerate failed or file missing"; @failed += 1
      return
    end
    body = File.read(@static)
    fish_ok = body.include?('#!/usr/bin/env fish') &&
              body.include?('set -gx PATH') &&
              body.include?("alias ll 'ls -la'")
    bash_leak = body.include?('export PATH=') || body.include?('typeset -U')
    if fish_ok && !bash_leak
      puts "✓"; @passed += 1
    else
      puts "✗"
      puts "  fish_ok=#{fish_ok} bash_leak=#{bash_leak}"
      @failed += 1
    end
  end
end

FishIntegrationTest.new.run if __FILE__ == $0
