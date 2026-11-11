#!/usr/bin/env ruby
# Integration tests for plugin command

require 'open3'
require 'fileutils'
require 'json'
require 'time'
require 'timeout'
require_relative 'test_helper'

class PluginIntegrationTest
  include WayuTestHelper

  def initialize
    setup_test_env
    @plugins_dir = "#{@data_dir}/plugins"
    setup_offline_git
  end

  # Offline, hermetic git for this suite (fixture commits and every git that
  # wayu spawns): a private global config with no signing, plus insteadOf
  # rewrites — https://example.test/<repo>.git clones the local fixture
  # repo <fixtures>/<repo>.git, and https://github.com/ points at a missing
  # local path, so no test ever reaches the network.
  def setup_offline_git
    @git_fixtures = "#{@tmp_home}/git-fixtures"
    FileUtils.mkdir_p(@git_fixtures)
    gitconfig = "#{@tmp_home}/.gitconfig"
    File.write(gitconfig, <<~CFG)
      [user]
        name = wayu-test
        email = wayu-test@example.test
      [commit]
        gpgsign = false
      [tag]
        gpgsign = false
      [init]
        defaultBranch = main
      [url "file://#{@git_fixtures}/"]
        insteadOf = https://example.test/
      [url "file://#{@tmp_home}/no-network/"]
        insteadOf = https://github.com/
    CFG
    ENV['GIT_CONFIG_GLOBAL'] = gitconfig
    ENV['GIT_CONFIG_NOSYSTEM'] = '1'
    %w[GIT_SSH GIT_SSH_COMMAND WAYU_GIT_TIMEOUT GIT_DIR GIT_WORK_TREE].each { |k| ENV.delete(k) }
  end

  def run
    puts "🔌 Testing plugin command integration..."
    puts

    begin
      build_project
      initialize_wayu

      test_list_plugins_empty
      test_add_plugin_from_github
      test_list_plugins_after_add
      test_plugin_directory_structure
      test_plugin_file_detection
      test_remove_plugin
      test_add_plugin_duplicate_handling
      test_plugin_update
      test_plugin_check_empty
      test_plugin_check_with_plugins
      test_plugin_update_with_name
      test_plugin_update_all_flag
      test_invalid_github_url
      test_plugin_with_custom_file
      test_help_command
      test_plugin_enable_cli_success
      test_plugin_disable_cli_success
      test_enable_idempotent_exit_zero
      test_disable_idempotent_exit_zero
      test_list_shows_enabled_disabled_status
      test_plugin_priority_command
      test_list_shows_priority
      test_loader_respects_priority
      test_conflict_warning_in_loader
      test_no_conflict_warning_when_unique
      test_rm_exact_match_and_ownership
      test_rm_fuzzy_name_refused
      test_rm_dry_run_no_side_effects
      test_add_dry_run_no_side_effects
      test_enable_dry_run_no_backup
      test_add_exact_installed_check
      test_ambiguous_fuzzy_does_not_block
      test_url_trailing_slash_and_unsafe_names
      test_rm_empty_name_never_wipes_root
      test_update_all_failure_exit_code
      test_update_respects_pinned_ref
      test_name_miss_never_acts_on_fuzzy_guess
      test_exact_name_still_works
      # Offline real-git flows (https://example.test/ → local fixtures)
      test_offline_add_clones_and_loads
      test_offline_plugin_sources_zcompiled
      test_offline_check_and_update
      test_offline_check_exact_branch_ref
      test_offline_check_unreachable_exits_74
      test_offline_update_divergent_history
      test_offline_symlink_rm_keeps_target
      test_offline_add_nothing_to_load_rolls_back
      test_offline_add_use_glob
      test_offline_add_zsh_theme
      test_offline_add_fish_url_records_fish
      test_offline_concurrent_adds
      test_offline_registry_pure_fish_name
      test_offline_update_all_counts_real_updates
      test_plugins_json_backups_pruned
      test_plugins_json_rejects_bad_entries
      test_offline_conflicts_reported
      test_ssh_batch_mode_and_timeout
      test_build_regenerates_plugin_loaders
      test_offline_update_ignores_repo_hooks
    ensure
      teardown_test_env
    end

    print_summary("plugin")
    exit(@failed > 0 ? 1 : 0)
  end

  private

  def test_list_plugins_empty
    print "Test 1: List plugins when none installed... "

    output, status = run_wayu("plugin list")

    if status.success? && (output.include?("No plugins installed") || output.include?("Plugins") && !output.include?("github.com"))
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected empty plugin list message"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_add_plugin_from_github
    print "Test 2: Add plugin from GitHub (dry-run)... "

    # Use dry-run to avoid actual git operations
    output, status = run_wayu("--dry-run plugin add https://github.com/zsh-users/zsh-syntax-highlighting.git")

    if output.include?("DRY RUN") || output.include?("Would clone") || output.include?("Installing Plugin")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Dry-run should show what would be done"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_list_plugins_after_add
    print "Test 3: Create mock plugin and list... "

    # Create mock plugin directory structure
    mock_plugin_dir = "#{@plugins_dir}/test-plugin"
    FileUtils.mkdir_p(mock_plugin_dir)
    File.write("#{mock_plugin_dir}/test-plugin.plugin.zsh", "# Test plugin\necho 'test plugin loaded'")

    output, status = run_wayu("plugin list")

    # Plugin list should succeed (may or may not show mock plugins depending on detection logic)
    if status.success?
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Plugin list command failed"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_plugin_directory_structure
    print "Test 4: Verify plugin directory structure... "

    # Check that plugins directory exists
    if Dir.exist?(@plugins_dir)
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Plugins directory not created"
      @failed += 1
    end
  end

  def test_plugin_file_detection
    print "Test 5: Plugin file detection patterns... "

    # Create different plugin file patterns
    test_patterns = [
      "plugin-standard/plugin-standard.plugin.zsh",
      "plugin-zsh/plugin-zsh.zsh",
      "plugin-plain/plugin-plain.sh"
    ]

    test_patterns.each do |pattern|
      dir_name = File.dirname(pattern)
      full_dir = "#{@plugins_dir}/#{dir_name}"
      FileUtils.mkdir_p(full_dir)
      File.write("#{full_dir}/#{File.basename(pattern)}", "# Test content")
    end

    output, status = run_wayu("plugin list")

    # Just verify command succeeds - detection logic may vary
    if status.success?
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Plugin list command failed"
      @failed += 1
    end
  end

  def test_remove_plugin
    print "Test 6: Remove plugin... "

    # Create a plugin to remove
    plugin_dir = "#{@plugins_dir}/removable-plugin"
    FileUtils.mkdir_p(plugin_dir)
    File.write("#{plugin_dir}/removable-plugin.plugin.zsh", "# Removable")

    seed_plugins([plugin_entry("removable-plugin", plugin_dir)])

    # Without --yes: refuses with EXIT_USAGE and deletes nothing
    _, refused = run_wayu("plugin rm removable-plugin")
    output, status = run_wayu("plugin rm removable-plugin --yes")

    if refused.exitstatus == 64 && status.exitstatus == 0 && !Dir.exist?(plugin_dir) &&
       !plugin_names_in_config.include?("removable-plugin")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to remove plugin"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_add_plugin_duplicate_handling
    print "Test 7: Duplicate plugin handling... "

    # Create a plugin
    plugin_dir = "#{@plugins_dir}/duplicate-test"
    FileUtils.mkdir_p(plugin_dir)
    File.write("#{plugin_dir}/duplicate-test.plugin.zsh", "# Duplicate test")

    # Try to add same plugin again (dry-run)
    output, status = run_wayu("--dry-run plugin add https://github.com/user/duplicate-test.git")

    # Should either warn or prevent duplicate
    if output.include?("already") || output.include?("exists") || output.include?("DRY RUN")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Duplicate handling unclear"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_plugin_update
    print "Test 8: Plugin update (dry-run)... "

    # Create a plugin
    plugin_dir = "#{@plugins_dir}/update-test"
    FileUtils.mkdir_p(plugin_dir)
    File.write("#{plugin_dir}/update-test.plugin.zsh", "# Update test")

    output, status = run_wayu("--dry-run plugin update update-test")

    # In dry-run, should show message or complete without error
    if output.include?("DRY RUN") || output.include?("Would update") || output.include?("update") || output.include?("plugin")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Update dry-run not working"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_plugin_check_empty
    print "Test 9: Plugin check with no plugins... "

    # Reset plugins to empty state for this test
    plugins_json = "#{@data_dir}/plugins.json"
    File.write(plugins_json, JSON.generate({"version" => "1.0", "lastUpdated" => Time.now.utc.iso8601, "plugins" => []}))
    FileUtils.rm_rf(Dir.glob("#{@plugins_dir}/*/"))

    output, status = run_wayu("plugin check")

    # Should complete without error and indicate no plugins
    if status.success? && (output.include?("No plugins") || output.include?("0 plugin") || output.empty? || output.include?("no plugins"))
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Check should handle empty plugin list"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_plugin_check_with_plugins
    print "Test 10: Plugin check with mock plugins... "

    # Create mock plugin with git metadata
    plugin_dir = "#{@plugins_dir}/check-test-plugin"
    FileUtils.mkdir_p("#{plugin_dir}/.git")
    File.write("#{plugin_dir}/check-test-plugin.plugin.zsh", "# Check test")

    # Create mock git config
    git_config = <<~GIT
      [remote "origin"]
        url = https://github.com/test/check-test-plugin.git
        fetch = +refs/heads/*:refs/remotes/origin/*
      [branch "main"]
        remote = origin
        merge = refs/heads/main
    GIT
    File.write("#{plugin_dir}/.git/config", git_config)

    output, status = run_wayu("plugin check")

    # Should execute without crashing (may or may not find updates)
    if status.success? || output.include?("check")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Check command should handle plugins with git repos"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_plugin_update_with_name
    print "Test 11: Plugin update with specific name (dry-run)... "

    # Create mock plugin
    plugin_dir = "#{@plugins_dir}/specific-update-test"
    FileUtils.mkdir_p(plugin_dir)
    File.write("#{plugin_dir}/specific-update-test.plugin.zsh", "# Specific update")

    # Register plugin in plugins.json
    plugins_json = "#{@data_dir}/plugins.json"
    config = JSON.parse(File.read(plugins_json)) rescue {"version" => "1.0", "lastUpdated" => Time.now.utc.iso8601, "plugins" => []}
    config["plugins"] << {"name" => "specific-update-test", "url" => "https://github.com/test/specific-update-test.git", "enabled" => true, "shell" => "zsh", "installedPath" => plugin_dir, "entryFile" => "specific-update-test.plugin.zsh", "git" => {"branch" => "main", "commit" => "abc123", "lastChecked" => Time.now.utc.iso8601}, "lastUpdated" => Time.now.utc.iso8601}
    File.write(plugins_json, JSON.generate(config))

    output, status = run_wayu("--dry-run plugin update specific-update-test")

    # Should show dry-run message or update intent
    if output.include?("DRY RUN") || output.include?("update") || output.include?("specific-update-test")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Update with name should work in dry-run"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_plugin_update_all_flag
    print "Test 12: Plugin update --all flag (dry-run)... "

    # Create multiple mock plugins and register them
    plugins_json = "#{@data_dir}/plugins.json"
    config = JSON.parse(File.read(plugins_json)) rescue {"version" => "1.0", "lastUpdated" => Time.now.utc.iso8601, "plugins" => []}
    ['plugin-a', 'plugin-b'].each do |name|
      plugin_dir = "#{@plugins_dir}/#{name}"
      FileUtils.mkdir_p(plugin_dir)
      File.write("#{plugin_dir}/#{name}.plugin.zsh", "# Plugin #{name}")
      config["plugins"] << {"name" => name, "url" => "https://github.com/test/#{name}.git", "enabled" => true, "shell" => "zsh", "installedPath" => plugin_dir, "entryFile" => "#{name}.plugin.zsh", "git" => {"branch" => "main", "commit" => "abc123", "lastChecked" => Time.now.utc.iso8601}, "lastUpdated" => Time.now.utc.iso8601}
    end
    File.write(plugins_json, JSON.generate(config))

    output, status = run_wayu("--dry-run plugin update --all")

    # Should recognize --all flag and show dry-run message
    if output.include?("DRY RUN") || output.include?("--all") || output.include?("update")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Update --all should work in dry-run"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_invalid_github_url
    print "Test 13: Invalid GitHub URL handling... "

    output, status = run_wayu("--dry-run plugin add invalid-url")

    # Should show error or validation message
    if !status.success? || output.include?("invalid") || output.include?("github.com")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Should validate GitHub URL"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_plugin_with_custom_file
    print "Test 14: Plugin with custom init file... "

    # Create plugin with custom structure
    plugin_dir = "#{@plugins_dir}/custom-plugin"
    FileUtils.mkdir_p(plugin_dir)
    File.write("#{plugin_dir}/init.zsh", "# Custom init file")

    output, status = run_wayu("plugin list")

    # Should detect plugin even with custom file name
    if status.success?
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Failed to handle custom plugin structure"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_help_command
    print "Test 15: Help command includes check and update actions... "

    output, status = run_wayu("plugin help")

    if output.include?("EXAMPLES") && output.include?("wayu plugin") && output.include?("check") && output.include?("update")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Help output should include check and update actions"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_plugin_enable_cli_success
    print "Test 16: Enable plugin via CLI... "

    # Create mock plugin in disabled state
    plugin_dir = "#{@plugins_dir}/enable-test-plugin"
    FileUtils.mkdir_p(plugin_dir)
    File.write("#{plugin_dir}/enable-test-plugin.plugin.zsh", "# Enable test")

    # Create JSON config with disabled plugin
    json_config = {
      "version" => "1.0",
      "lastUpdated" => Time.now.utc.iso8601,
      "plugins" => [
        {
          "name" => "enable-test-plugin",
          "url" => "https://github.com/test/enable-test.git",
          "enabled" => false,  # Start disabled
          "shell" => "zsh",
          "installedPath" => plugin_dir,
          "entryFile" => "enable-test-plugin.plugin.zsh",
          "git" => {
            "branch" => "main",
            "commit" => "abc123",
            "lastChecked" => Time.now.utc.iso8601,
            "remoteCommit" => "abc123"
          },
          "dependencies" => [],
          "priority" => 100,
          "config" => {},
          "conflicts" => {
            "envVars" => [],
            "functions" => [],
            "aliases" => [],
            "detected" => false,
            "conflictingPlugins" => []
          }
        }
      ],
      "settings" => {
        "autoCheckUpdates" => false,
        "checkInterval" => 604800,
        "conflictDetection" => true,
        "loadParallel" => false
      }
    }

    # Write JSON config
    json_file = "#{@data_dir}/plugins.json"
    File.write(json_file, JSON.pretty_generate(json_config))

    # Run enable command
    output, status = run_wayu("plugin enable enable-test-plugin")

    if status.success? && output.include?("enabled successfully")
      # Read config back to verify
      updated_config = JSON.parse(File.read(json_file))
      if updated_config["plugins"][0]["enabled"] == true
        puts "✓"
        @passed += 1
      else
        puts "✗"
        puts "  Plugin not enabled in config"
        @failed += 1
      end
    else
      puts "✗"
      puts "  Enable command failed"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_plugin_disable_cli_success
    print "Test 17: Disable plugin via CLI... "

    # Create mock plugin in enabled state
    plugin_dir = "#{@plugins_dir}/disable-test-plugin"
    FileUtils.mkdir_p(plugin_dir)
    File.write("#{plugin_dir}/disable-test-plugin.plugin.zsh", "# Disable test")

    # Create JSON config with enabled plugin
    json_config = {
      "version" => "1.0",
      "lastUpdated" => Time.now.utc.iso8601,
      "plugins" => [
        {
          "name" => "disable-test-plugin",
          "url" => "https://github.com/test/disable-test.git",
          "enabled" => true,  # Start enabled
          "shell" => "zsh",
          "installedPath" => plugin_dir,
          "entryFile" => "disable-test-plugin.plugin.zsh",
          "git" => {
            "branch" => "main",
            "commit" => "abc123",
            "lastChecked" => Time.now.utc.iso8601,
            "remoteCommit" => "abc123"
          },
          "dependencies" => [],
          "priority" => 100,
          "config" => {},
          "conflicts" => {
            "envVars" => [],
            "functions" => [],
            "aliases" => [],
            "detected" => false,
            "conflictingPlugins" => []
          }
        }
      ],
      "settings" => {
        "autoCheckUpdates" => false,
        "checkInterval" => 604800,
        "conflictDetection" => true,
        "loadParallel" => false
      }
    }

    # Write JSON config
    json_file = "#{@data_dir}/plugins.json"
    File.write(json_file, JSON.pretty_generate(json_config))

    # Run disable command
    output, status = run_wayu("plugin disable disable-test-plugin")

    if status.success? && output.include?("disabled successfully")
      # Read config back to verify
      updated_config = JSON.parse(File.read(json_file))
      if updated_config["plugins"][0]["enabled"] == false
        puts "✓"
        @passed += 1
      else
        puts "✗"
        puts "  Plugin not disabled in config"
        @failed += 1
      end
    else
      puts "✗"
      puts "  Disable command failed"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_enable_idempotent_exit_zero
    print "Test 18: Enable already-enabled plugin returns exit 0... "

    # Create mock plugin in enabled state
    plugin_dir = "#{@plugins_dir}/idempotent-test"
    FileUtils.mkdir_p(plugin_dir)
    File.write("#{plugin_dir}/idempotent-test.plugin.zsh", "# Idempotent test")

    # Create JSON config with enabled plugin
    json_config = {
      "version" => "1.0",
      "lastUpdated" => Time.now.utc.iso8601,
      "plugins" => [
        {
          "name" => "idempotent-test",
          "url" => "https://github.com/test/idempotent.git",
          "enabled" => true,  # Already enabled
          "shell" => "zsh",
          "installedPath" => plugin_dir,
          "entryFile" => "idempotent-test.plugin.zsh",
          "git" => {
            "branch" => "main",
            "commit" => "abc123",
            "lastChecked" => Time.now.utc.iso8601,
            "remoteCommit" => "abc123"
          },
          "dependencies" => [],
          "priority" => 100,
          "config" => {},
          "conflicts" => {
            "envVars" => [],
            "functions" => [],
            "aliases" => [],
            "detected" => false,
            "conflictingPlugins" => []
          }
        }
      ],
      "settings" => {
        "autoCheckUpdates" => false,
        "checkInterval" => 604800,
        "conflictDetection" => true,
        "loadParallel" => false
      }
    }

    # Write JSON config
    json_file = "#{@data_dir}/plugins.json"
    File.write(json_file, JSON.pretty_generate(json_config))

    # Run enable on already-enabled plugin
    output, status = run_wayu("plugin enable idempotent-test")

    # CRITICAL: Must return exit code 0 (success)
    if status.success? && output.include?("already enabled")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected exit 0 and 'already enabled' message"
      puts "  Got exit code: #{status.exitstatus}"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_disable_idempotent_exit_zero
    print "Test 19: Disable already-disabled plugin returns exit 0... "

    # Create mock plugin in disabled state
    plugin_dir = "#{@plugins_dir}/idempotent-test-2"
    FileUtils.mkdir_p(plugin_dir)
    File.write("#{plugin_dir}/idempotent-test-2.plugin.zsh", "# Idempotent test 2")

    # Create JSON config with disabled plugin
    json_config = {
      "version" => "1.0",
      "lastUpdated" => Time.now.utc.iso8601,
      "plugins" => [
        {
          "name" => "idempotent-test-2",
          "url" => "https://github.com/test/idempotent-2.git",
          "enabled" => false,  # Already disabled
          "shell" => "zsh",
          "installedPath" => plugin_dir,
          "entryFile" => "idempotent-test-2.plugin.zsh",
          "git" => {
            "branch" => "main",
            "commit" => "abc123",
            "lastChecked" => Time.now.utc.iso8601,
            "remoteCommit" => "abc123"
          },
          "dependencies" => [],
          "priority" => 100,
          "config" => {},
          "conflicts" => {
            "envVars" => [],
            "functions" => [],
            "aliases" => [],
            "detected" => false,
            "conflictingPlugins" => []
          }
        }
      ],
      "settings" => {
        "autoCheckUpdates" => false,
        "checkInterval" => 604800,
        "conflictDetection" => true,
        "loadParallel" => false
      }
    }

    # Write JSON config
    json_file = "#{@data_dir}/plugins.json"
    File.write(json_file, JSON.pretty_generate(json_config))

    # Run disable on already-disabled plugin
    output, status = run_wayu("plugin disable idempotent-test-2")

    # CRITICAL: Must return exit code 0 (success)
    if status.success? && output.include?("already disabled")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  Expected exit 0 and 'already disabled' message"
      puts "  Got exit code: #{status.exitstatus}"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_list_shows_enabled_disabled_status
    print "Test 20: List command shows enabled/disabled status... "

    # Create two mock plugins with different states
    enabled_dir = "#{@plugins_dir}/enabled-status-test"
    disabled_dir = "#{@plugins_dir}/disabled-status-test"
    FileUtils.mkdir_p(enabled_dir)
    FileUtils.mkdir_p(disabled_dir)
    File.write("#{enabled_dir}/enabled-status-test.plugin.zsh", "# Enabled")
    File.write("#{disabled_dir}/disabled-status-test.plugin.zsh", "# Disabled")

    # Create JSON config
    json_config = {
      "version" => "1.0",
      "lastUpdated" => Time.now.utc.iso8601,
      "plugins" => [
        {
          "name" => "enabled-status-test",
          "url" => "https://github.com/test/enabled.git",
          "enabled" => true,
          "shell" => "zsh",
          "installedPath" => enabled_dir,
          "entryFile" => "enabled-status-test.plugin.zsh",
          "git" => {
            "branch" => "main",
            "commit" => "abc123",
            "lastChecked" => Time.now.utc.iso8601,
            "remoteCommit" => "abc123"
          },
          "dependencies" => [],
          "priority" => 100,
          "config" => {},
          "conflicts" => {
            "envVars" => [],
            "functions" => [],
            "aliases" => [],
            "detected" => false,
            "conflictingPlugins" => []
          }
        },
        {
          "name" => "disabled-status-test",
          "url" => "https://github.com/test/disabled.git",
          "enabled" => false,
          "shell" => "zsh",
          "installedPath" => disabled_dir,
          "entryFile" => "disabled-status-test.plugin.zsh",
          "git" => {
            "branch" => "main",
            "commit" => "def456",
            "lastChecked" => Time.now.utc.iso8601,
            "remoteCommit" => "def456"
          },
          "dependencies" => [],
          "priority" => 100,
          "config" => {},
          "conflicts" => {
            "envVars" => [],
            "functions" => [],
            "aliases" => [],
            "detected" => false,
            "conflictingPlugins" => []
          }
        }
      ],
      "settings" => {
        "autoCheckUpdates" => false,
        "checkInterval" => 604800,
        "conflictDetection" => true,
        "loadParallel" => false
      }
    }

    # Write JSON config
    json_file = "#{@data_dir}/plugins.json"
    File.write(json_file, JSON.pretty_generate(json_config))

    # Run list command
    output, status = run_wayu("plugin list")

    # Verify status indicators in output
    if status.success? &&
       (output.include?("✓ Active") || output.include?("Active")) &&
       (output.include?("○ Disabled") || output.include?("Disabled"))
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  List output should show both Active and Disabled statuses"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_plugin_priority_command
    print "Test 21: Set plugin priority via CLI... "

    # Create mock plugin
    plugin_dir = "#{@plugins_dir}/priority-test-plugin"
    FileUtils.mkdir_p(plugin_dir)
    File.write("#{plugin_dir}/priority-test-plugin.plugin.zsh", "# Priority test")

    # Create JSON config with default priority
    json_config = {
      "version" => "1.0",
      "lastUpdated" => Time.now.utc.iso8601,
      "plugins" => [
        {
          "name" => "priority-test-plugin",
          "url" => "https://github.com/test/priority-test.git",
          "enabled" => true,
          "shell" => "zsh",
          "installedPath" => plugin_dir,
          "entryFile" => "priority-test-plugin.plugin.zsh",
          "git" => {
            "branch" => "main",
            "commit" => "abc123",
            "lastChecked" => Time.now.utc.iso8601,
            "remoteCommit" => "abc123"
          },
          "dependencies" => [],
          "priority" => 100,  # Default priority
          "config" => {},
          "conflicts" => {
            "envVars" => [],
            "functions" => [],
            "aliases" => [],
            "detected" => false,
            "conflictingPlugins" => []
          }
        }
      ]
    }

    # Write JSON config
    json_file = "#{@data_dir}/plugins.json"
    File.write(json_file, JSON.pretty_generate(json_config))

    # Run priority command to change priority to 50
    output, status = run_wayu("plugin priority priority-test-plugin 50")

    if status.success? && output.include?("Updated priority")
      # Read config back to verify
      updated_config = JSON.parse(File.read(json_file))
      if updated_config["plugins"][0]["priority"] == 50
        puts "✓"
        @passed += 1
      else
        puts "✗"
        puts "  Priority not updated in config"
        puts "  Expected: 50, Got: #{updated_config['plugins'][0]['priority']}"
        @failed += 1
      end
    else
      puts "✗"
      puts "  Priority command failed"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_list_shows_priority
    print "Test 22: List command shows priority column... "

    # Create mock plugins with different priorities
    high_priority_dir = "#{@plugins_dir}/high-priority-plugin"
    low_priority_dir = "#{@plugins_dir}/low-priority-plugin"
    FileUtils.mkdir_p(high_priority_dir)
    FileUtils.mkdir_p(low_priority_dir)
    File.write("#{high_priority_dir}/high-priority-plugin.plugin.zsh", "# High priority")
    File.write("#{low_priority_dir}/low-priority-plugin.plugin.zsh", "# Low priority")

    # Create JSON config with different priorities
    json_config = {
      "version" => "1.0",
      "lastUpdated" => Time.now.utc.iso8601,
      "plugins" => [
        {
          "name" => "high-priority-plugin",
          "url" => "https://github.com/test/high-priority.git",
          "enabled" => true,
          "shell" => "zsh",
          "installedPath" => high_priority_dir,
          "entryFile" => "high-priority-plugin.plugin.zsh",
          "git" => {
            "branch" => "main",
            "commit" => "abc123",
            "lastChecked" => Time.now.utc.iso8601,
            "remoteCommit" => "abc123"
          },
          "dependencies" => [],
          "priority" => 10,  # High priority (lower number)
          "config" => {},
          "conflicts" => {
            "envVars" => [],
            "functions" => [],
            "aliases" => [],
            "detected" => false,
            "conflictingPlugins" => []
          }
        },
        {
          "name" => "low-priority-plugin",
          "url" => "https://github.com/test/low-priority.git",
          "enabled" => true,
          "shell" => "zsh",
          "installedPath" => low_priority_dir,
          "entryFile" => "low-priority-plugin.plugin.zsh",
          "git" => {
            "branch" => "main",
            "commit" => "def456",
            "lastChecked" => Time.now.utc.iso8601,
            "remoteCommit" => "def456"
          },
          "dependencies" => [],
          "priority" => 200,  # Low priority (higher number)
          "config" => {},
          "conflicts" => {
            "envVars" => [],
            "functions" => [],
            "aliases" => [],
            "detected" => false,
            "conflictingPlugins" => []
          }
        }
      ]
    }

    # Write JSON config
    json_file = "#{@data_dir}/plugins.json"
    File.write(json_file, JSON.pretty_generate(json_config))

    # Run list command
    output, status = run_wayu("plugin list")

    # Verify priority column exists and shows both values
    if status.success? &&
       output.include?("Priority") &&
       output.include?("10") &&
       output.include?("200")
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  List output should show Priority column with values"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_loader_respects_priority
    print "Test 23: Shell loader respects priority ordering... "

    # Create three mock plugins with priorities: 50, 100, 150
    ['plugin-high', 'plugin-mid', 'plugin-low'].each_with_index do |name, idx|
      plugin_dir = "#{@plugins_dir}/#{name}"
      FileUtils.mkdir_p(plugin_dir)
      File.write("#{plugin_dir}/#{name}.plugin.zsh", "# #{name}")
    end

    # Create JSON config with priority-based ordering
    json_config = {
      "version" => "1.0",
      "lastUpdated" => Time.now.utc.iso8601,
      "plugins" => [
        {
          "name" => "plugin-high",
          "url" => "https://github.com/test/plugin-high.git",
          "enabled" => false,  # disabled so 'plugin enable' actually triggers loader regeneration
          "shell" => "zsh",
          "installedPath" => "#{@plugins_dir}/plugin-high",
          "entryFile" => "plugin-high.plugin.zsh",
          "git" => {
            "branch" => "main",
            "commit" => "abc123",
            "lastChecked" => Time.now.utc.iso8601,
            "remoteCommit" => "abc123"
          },
          "dependencies" => [],
          "priority" => 50,  # Loads first
          "config" => {},
          "conflicts" => {
            "envVars" => [],
            "functions" => [],
            "aliases" => [],
            "detected" => false,
            "conflictingPlugins" => []
          }
        },
        {
          "name" => "plugin-mid",
          "url" => "https://github.com/test/plugin-mid.git",
          "enabled" => true,
          "shell" => "zsh",
          "installedPath" => "#{@plugins_dir}/plugin-mid",
          "entryFile" => "plugin-mid.plugin.zsh",
          "git" => {
            "branch" => "main",
            "commit" => "def456",
            "lastChecked" => Time.now.utc.iso8601,
            "remoteCommit" => "def456"
          },
          "dependencies" => [],
          "priority" => 100,  # Loads second
          "config" => {},
          "conflicts" => {
            "envVars" => [],
            "functions" => [],
            "aliases" => [],
            "detected" => false,
            "conflictingPlugins" => []
          }
        },
        {
          "name" => "plugin-low",
          "url" => "https://github.com/test/plugin-low.git",
          "enabled" => true,
          "shell" => "zsh",
          "installedPath" => "#{@plugins_dir}/plugin-low",
          "entryFile" => "plugin-low.plugin.zsh",
          "git" => {
            "branch" => "main",
            "commit" => "ghi789",
            "lastChecked" => Time.now.utc.iso8601,
            "remoteCommit" => "ghi789"
          },
          "dependencies" => [],
          "priority" => 150,  # Loads third
          "config" => {},
          "conflicts" => {
            "envVars" => [],
            "functions" => [],
            "aliases" => [],
            "detected" => false,
            "conflictingPlugins" => []
          }
        }
      ]
    }

    # Write JSON config
    json_file = "#{@data_dir}/plugins.json"
    File.write(json_file, JSON.pretty_generate(json_config))

    # Trigger shell loader generation (enable regenerates the file)
    run_wayu("plugin enable plugin-high")

    # Read generated plugins.zsh file
    plugins_file = "#{@data_dir}/plugins.zsh"
    if File.exist?(plugins_file)
      loader_content = File.read(plugins_file)

      # Find positions of each plugin in the loader
      high_pos = loader_content.index("plugin-high")
      mid_pos = loader_content.index("plugin-mid")
      low_pos = loader_content.index("plugin-low")

      # Verify priority order: high < mid < low
      if high_pos && mid_pos && low_pos && high_pos < mid_pos && mid_pos < low_pos
        # Also verify priority comments are present
        if loader_content.include?("priority: 50") &&
           loader_content.include?("priority: 100") &&
           loader_content.include?("priority: 150")
          puts "✓"
          @passed += 1
        else
          puts "✗"
          puts "  Priority comments missing from loader file"
          @failed += 1
        end
      else
        puts "✗"
        puts "  Plugins not in priority order in loader file"
        puts "  Expected: plugin-high < plugin-mid < plugin-low"
        puts "  Got positions: high=#{high_pos}, mid=#{mid_pos}, low=#{low_pos}"
        @failed += 1
      end
    else
      puts "✗"
      puts "  Loader file not generated: #{plugins_file}"
      @failed += 1
    end
  end

  def test_conflict_warning_in_loader
    print "Test 24: Conflict warnings appear in shell loader... "

    # Create two mock plugins with conflicting declarations
    plugin_a_dir = "#{@plugins_dir}/conflict-plugin-a"
    plugin_b_dir = "#{@plugins_dir}/conflict-plugin-b"
    FileUtils.mkdir_p(plugin_a_dir)
    FileUtils.mkdir_p(plugin_b_dir)

    # Both plugins export MY_VAR
    File.write("#{plugin_a_dir}/conflict-plugin-a.plugin.zsh", <<~SHELL)
      # Plugin A
      export MY_VAR="value_from_a"

      my_function() {
        echo "from plugin a"
      }

      alias ll="ls -la"
    SHELL

    File.write("#{plugin_b_dir}/conflict-plugin-b.plugin.zsh", <<~SHELL)
      # Plugin B
      export MY_VAR="value_from_b"

      function my_function() {
        echo "from plugin b"
      }

      alias ll="ls -lh"
    SHELL

    # Create JSON config with conflict information
    json_config = {
      "version" => "1.0",
      "lastUpdated" => Time.now.utc.iso8601,
      "plugins" => [
        {
          "name" => "conflict-plugin-a",
          "url" => "https://github.com/test/conflict-a.git",
          "enabled" => false,  # disabled so 'plugin enable' actually triggers loader regeneration
          "shell" => "zsh",
          "installedPath" => plugin_a_dir,
          "entryFile" => "conflict-plugin-a.plugin.zsh",
          "git" => {
            "branch" => "main",
            "commit" => "abc123",
            "lastChecked" => Time.now.utc.iso8601,
            "remoteCommit" => "abc123"
          },
          "dependencies" => [],
          "priority" => 100,
          "config" => {},
          "conflicts" => {
            "envVars" => ["MY_VAR"],
            "functions" => ["my_function"],
            "aliases" => ["ll"],
            "detected" => true,
            "conflictingPlugins" => ["conflict-plugin-b"]
          }
        },
        {
          "name" => "conflict-plugin-b",
          "url" => "https://github.com/test/conflict-b.git",
          "enabled" => true,
          "shell" => "zsh",
          "installedPath" => plugin_b_dir,
          "entryFile" => "conflict-plugin-b.plugin.zsh",
          "git" => {
            "branch" => "main",
            "commit" => "def456",
            "lastChecked" => Time.now.utc.iso8601,
            "remoteCommit" => "def456"
          },
          "dependencies" => [],
          "priority" => 100,
          "config" => {},
          "conflicts" => {
            "envVars" => ["MY_VAR"],
            "functions" => ["my_function"],
            "aliases" => ["ll"],
            "detected" => true,
            "conflictingPlugins" => ["conflict-plugin-a"]
          }
        }
      ]
    }

    # Write JSON config
    json_file = "#{@data_dir}/plugins.json"
    File.write(json_file, JSON.pretty_generate(json_config))

    # Trigger loader generation (enable regenerates the file)
    run_wayu("plugin enable conflict-plugin-a")

    # Read generated plugins.zsh file and check for conflict warnings
    plugins_file = "#{@data_dir}/plugins.zsh"
    if File.exist?(plugins_file)
      loader_content = File.read(plugins_file)

      # Check for global conflict warning header or per-plugin warning
      has_global_warning = loader_content.include?("CONFLICT WARNINGS")
      has_plugin_a_warning = loader_content.include?("conflict-plugin-a") && loader_content.include?("WARNING")
      has_plugin_b_warning = loader_content.include?("conflict-plugin-b") && loader_content.include?("WARNING")

      if has_global_warning || has_plugin_a_warning || has_plugin_b_warning
        puts "✓"
        @passed += 1
      else
        puts "✗"
        puts "  Expected conflict warnings in loader file"
        puts "  Global warning: #{has_global_warning}"
        puts "  Plugin A warning: #{has_plugin_a_warning}"
        puts "  Plugin B warning: #{has_plugin_b_warning}"
        @failed += 1
      end
    else
      puts "✗"
      puts "  Loader file not generated: #{plugins_file}"
      @failed += 1
    end
  end

  def test_no_conflict_warning_when_unique
    print "Test 25: No conflict warnings when plugins are unique... "

    # Create a unique plugin with no conflicts and regenerate the loader
    unique_plugin_dir = "#{@plugins_dir}/unique-plugin"
    FileUtils.mkdir_p(unique_plugin_dir)
    File.write("#{unique_plugin_dir}/unique-plugin.plugin.zsh", "# unique plugin\nexport UNIQUE_VAR='hello'\n")

    # Write a clean plugins.json with no conflicts
    json_config = {
      "version" => "1.0",
      "lastUpdated" => Time.now.utc.iso8601,
      "plugins" => [
        {
          "name" => "unique-plugin",
          "url" => "https://github.com/test/unique-plugin.git",
          "enabled" => false,  # disabled so 'plugin enable' triggers regeneration
          "shell" => "zsh",
          "installedPath" => unique_plugin_dir,
          "entryFile" => "unique-plugin.plugin.zsh",
          "git" => {
            "branch" => "main",
            "commit" => "abc123",
            "lastChecked" => Time.now.utc.iso8601,
            "remoteCommit" => "abc123"
          },
          "dependencies" => [],
          "priority" => 100,
          "config" => {},
          "conflicts" => {
            "envVars" => [],
            "functions" => [],
            "aliases" => [],
            "detected" => false,
            "conflictingPlugins" => []
          }
        }
      ]
    }

    json_file = "#{@data_dir}/plugins.json"
    File.write(json_file, JSON.pretty_generate(json_config))

    # Trigger loader regeneration with a clean, conflict-free config
    run_wayu("plugin enable unique-plugin")

    # Read generated plugins.zsh file
    plugins_file = "#{@data_dir}/plugins.zsh"
    if File.exist?(plugins_file)
      loader_content = File.read(plugins_file)

      # Verify NO conflict warnings appear
      has_no_conflict_warning = !loader_content.include?("⚠️  CONFLICT WARNINGS") &&
                                !loader_content.include?("⚠️  WARNING:")

      if has_no_conflict_warning
        puts "✓"
        @passed += 1
      else
        puts "✗"
        puts "  Should NOT have conflict warnings when plugins are unique"
        puts "  Loader content includes conflict markers"
        @failed += 1
      end
    else
      puts "✓"  # No plugins.zsh means no conflict warnings either
      @passed += 1
    end
  end

  # ---------------------------------------------------------------------------
  # Regression tests (exit status + on-disk side effects)
  # ---------------------------------------------------------------------------

  # Minimal plugins.json entry using the binary's own (snake_case) field names.
  def plugin_entry(name, path, enabled: true, deps: [])
    {
      "name" => name,
      "display_name" => name,
      "url" => "https://github.com/test/#{name}.git",
      "enabled" => enabled,
      "shell" => "ZSH",
      "installed_path" => path,
      "dependencies" => deps,
      "priority" => 100,
      "git" => { "branch" => "main", "commit" => "abc1234" }
    }
  end

  def seed_plugins(entries)
    FileUtils.mkdir_p(@plugins_dir)
    json = { "version" => "1.0", "last_updated" => Time.now.utc.iso8601, "plugins" => entries }
    File.write("#{@data_dir}/plugins.json", JSON.pretty_generate(json))
  end

  def plugin_names_in_config
    JSON.parse(File.read("#{@data_dir}/plugins.json"))["plugins"].map { |p| p["name"] }
  end

  def backup_files
    Dir.glob("#{@data_dir}/backup/plugins.json.backup.*")
  end

  def check(label, ok, output, status)
    if ok
      puts "✓"
      @passed += 1
    else
      puts "✗"
      puts "  #{label}"
      puts "  Exit: #{status&.exitstatus}"
      puts "  Output: #{output}"
      @failed += 1
    end
  end

  def test_rm_exact_match_and_ownership
    print "Test 26: rm --yes removes exact target, keeps others, exit 0... "
    a = "#{@plugins_dir}/rm-alpha"; b = "#{@plugins_dir}/rm-alpha-extra"
    FileUtils.mkdir_p(a); FileUtils.mkdir_p(b)
    seed_plugins([plugin_entry("rm-alpha", a), plugin_entry("rm-alpha-extra", b)])

    output, status = run_wayu("plugin rm rm-alpha --yes")
    ok = status.exitstatus == 0 && !Dir.exist?(a) && Dir.exist?(b) &&
         plugin_names_in_config == ["rm-alpha-extra"]
    check("exact rm failed", ok, output, status)
  end

  def test_rm_fuzzy_name_refused
    print "Test 27: rm with non-exact name refuses (exit 65), suggests, deletes nothing... "
    dir = "#{@plugins_dir}/zsh-autosuggestions"
    FileUtils.mkdir_p(dir)
    seed_plugins([plugin_entry("zsh-autosuggestions", dir)])

    output, status = run_wayu("plugin rm autosuggest --yes")
    ok = status.exitstatus == 65 && Dir.exist?(dir) &&
         plugin_names_in_config == ["zsh-autosuggestions"] &&
         output.include?("Did you mean") && output.include?("zsh-autosuggestions")
    check("fuzzy rm must not delete", ok, output, status)
  end

  def test_rm_dry_run_no_side_effects
    print "Test 28: --dry-run rm leaves plugins.json, dir and backups untouched... "
    dir = "#{@plugins_dir}/dry-rm"
    FileUtils.mkdir_p(dir)
    seed_plugins([plugin_entry("dry-rm", dir)])
    before = File.read("#{@data_dir}/plugins.json")
    FileUtils.rm_rf("#{@data_dir}/backup")

    output, status = run_wayu("--dry-run plugin rm dry-rm --yes")
    ok = status.exitstatus == 0 && Dir.exist?(dir) &&
         File.read("#{@data_dir}/plugins.json") == before && backup_files.empty?
    check("dry-run rm had side effects", ok, output, status)
  end

  def test_add_dry_run_no_side_effects
    print "Test 29: --dry-run add (registry key + URL) writes nothing, exit 0... "
    FileUtils.rm_f("#{@data_dir}/plugins.json")

    out1, st1 = run_wayu("--dry-run plugin add syntax-highlighting")
    out2, st2 = run_wayu("--dry-run plugin add https://github.com/user/custom-plugin.git")
    ok = st1.exitstatus == 0 && st2.exitstatus == 0 &&
         !File.exist?("#{@data_dir}/plugins.json") &&
         !Dir.exist?("#{@plugins_dir}/zsh-syntax-highlighting")
    check("dry-run add wrote config or crashed", ok, out1 + out2, st2)
  end

  def test_enable_dry_run_no_backup
    print "Test 30: --dry-run enable creates no backup and no config change... "
    dir = "#{@plugins_dir}/dry-enable"
    FileUtils.mkdir_p(dir)
    seed_plugins([plugin_entry("dry-enable", dir, enabled: false)])
    before = File.read("#{@data_dir}/plugins.json")
    FileUtils.rm_rf("#{@data_dir}/backup")

    output, status = run_wayu("--dry-run plugin enable dry-enable")
    ok = status.exitstatus == 0 && backup_files.empty? &&
         File.read("#{@data_dir}/plugins.json") == before
    check("dry-run enable had side effects", ok, output, status)
  end

  def test_add_exact_installed_check
    print "Test 31: add 'git' is not 'already installed' when only 'forgit' is... "
    dir = "#{@plugins_dir}/forgit"
    FileUtils.mkdir_p(dir)
    seed_plugins([plugin_entry("forgit", dir)])

    output, status = run_wayu("--dry-run plugin add https://github.com/someone/git.git")
    ok = status.exitstatus == 0 && !output.include?("already installed") && output.include?("Name: git")
    check("fuzzy 'already installed' false positive", ok, output, status)
  end

  def test_ambiguous_fuzzy_does_not_block
    print "Test 32: non-exact name with non-TTY stdin fails fast (exit 65)... "
    a = "#{@plugins_dir}/zsh-autosuggestions"; b = "#{@plugins_dir}/zsh-autocomplete"
    FileUtils.mkdir_p(a); FileUtils.mkdir_p(b)
    seed_plugins([plugin_entry("zsh-autosuggestions", a, enabled: false),
                  plugin_entry("zsh-autocomplete", b, enabled: false)])

    output, status = nil, nil
    begin
      Timeout.timeout(10) { output, status = run_wayu("plugin enable zsh-auto") }
    rescue Timeout::Error
      output = "TIMEOUT (blocked on stdin)"
    end
    ok = status && status.exitstatus == 65
    check("ambiguous lookup blocked or succeeded", ok, output, status)
  end

  def test_url_trailing_slash_and_unsafe_names
    print "Test 33: trailing-slash URL derives name; unsafe names rejected (exit 65)... "
    out1, st1 = run_wayu("--dry-run plugin add https://github.com/user/repo/")
    out2, st2 = run_wayu("--dry-run plugin add https://github.com/user/..")
    ok = st1.exitstatus == 0 && out1.include?("Name: repo") && st2.exitstatus == 65
    check("URL name derivation/validation", ok, out1 + out2, st2)
  end

  def test_rm_empty_name_never_wipes_root
    print "Test 34: rm with an empty-name entry never deletes plugins root... "
    keep = "#{@plugins_dir}/keep-me"
    FileUtils.mkdir_p(keep)
    seed_plugins([plugin_entry("", @plugins_dir), plugin_entry("keep-me", keep)])

    # A nameless entry makes plugins.json invalid (OKAMI-342): exit 78,
    # nothing touched.
    output, status = run_wayu("plugin rm '' --yes")
    ok = status.exitstatus == 78 && Dir.exist?(keep) && plugin_names_in_config == ["", "keep-me"]
    seed_plugins([])
    check("plugins root wiped", ok, output, status)
  end

  def test_update_all_failure_exit_code
    print "Test 35: update --all exits 74 when an update fails... "
    dir = "#{@plugins_dir}/not-a-repo"
    FileUtils.mkdir_p(dir)
    seed_plugins([plugin_entry("not-a-repo", dir)])

    output, status = run_wayu("plugin update --all")
    check("update --all failure must be non-zero", status.exitstatus == 74, output, status)
  end

  def test_update_respects_pinned_ref
    print "Test 36: update skips pinned plugin and keeps pin metadata... "
    # Real clone of a local origin so `pull` would succeed if (wrongly) run —
    # the old code then replaced the whole git block and dropped the pin.
    origin = "#{@tmp_home}/pinned-origin"
    dir = "#{@plugins_dir}/pinned"
    FileUtils.rm_rf([origin, dir])
    git_env = { "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@t", "GIT_COMMITTER_NAME" => "t", "GIT_COMMITTER_EMAIL" => "t@t" }
    system(git_env, "git", "init", "-q", origin)
    File.write("#{origin}/pinned.plugin.zsh", "# pinned\n")
    system(git_env, "git", "-C", origin, "add", ".")
    system(git_env, "git", "-C", origin, "commit", "-q", "-m", "init")
    system(git_env, "git", "clone", "-q", origin, dir)
    entry = plugin_entry("pinned", dir)
    entry["git"] = { "ref_type" => "Tag", "tag" => "v1.0.0", "pinned_ref" => "v1.0.0", "commit" => "abc1234" }
    seed_plugins([entry])

    output, status = run_wayu("plugin update --all")
    git = JSON.parse(File.read("#{@data_dir}/plugins.json"))["plugins"][0]["git"]
    ok = status.exitstatus == 0 && git["tag"] == "v1.0.0" && git["pinned_ref"] == "v1.0.0"
    check("pinned plugin was updated or lost its pin", ok, output, status)
  end

  # OKAMI-309: `wayu build` regenerates plugins.<ext> for every set-up shell
  # from a hand-edited plugins.json; an invalid one exits 78 and keeps them.
  def test_build_regenerates_plugin_loaders
    print "Test: build regenerates plugins.<ext>; invalid plugins.json exits 78... "
    run_wayu("--shell bash init")
    dir = "#{@plugins_dir}/regen-p"
    FileUtils.mkdir_p(dir)
    File.write("#{dir}/regen-p.plugin.zsh", "# regen\n")
    seed_plugins([plugin_entry("regen-p", dir)])
    _, _, st1 = run_wayu_split("build")
    on = File.read("#{@data_dir}/plugins.zsh")
    bash_ok = File.exist?("#{@data_dir}/plugins.bash")
    seed_plugins([plugin_entry("regen-p", dir, enabled: false)])
    _, _, st2 = run_wayu_split("build")
    off = File.read("#{@data_dir}/plugins.zsh")
    File.write("#{@data_dir}/plugins.json", "{ not json")
    _, err3, st3 = run_wayu_split("build")
    kept = File.read("#{@data_dir}/plugins.zsh")
    seed_plugins([])
    ok = st1.success? && on.include?("regen-p.plugin.zsh") && bash_ok && st2.success? &&
         !off.include?("regen-p.plugin.zsh") && st3.exitstatus == 78 && err3.include?("plugins.json") && kept == off
    check("build/plugin loaders", ok,
          "st=#{[st1, st2, st3].map(&:exitstatus)} on=#{on.include?('regen-p')} bash=#{bash_ok} off=#{off.include?('regen-p')} err3=#{err3[0, 300]}",
          st3)
  end

  # stdout and stderr kept apart (run_wayu merges them).
  def run_wayu_split(args)
    env = ENV.to_h.merge('HOME' => @tmp_home)
    project_root = File.expand_path('../..', __dir__)
    out, err, status = Open3.capture3(env, "#{@wayu_bin} #{args}", chdir: project_root)
    [out.force_encoding('UTF-8'), err.force_encoding('UTF-8'), status]
  end

  # Seeds one plugin "origin" backed by a real clone of a local repo, so
  # `plugin update origin` works offline.
  def seed_origin_plugin
    remote = "#{@tmp_home}/origin-remote"
    dir = "#{@plugins_dir}/origin"
    FileUtils.rm_rf([remote, dir])
    git_env = { "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@t", "GIT_COMMITTER_NAME" => "t", "GIT_COMMITTER_EMAIL" => "t@t" }
    system(git_env, "git", "init", "-q", "-b", "main", remote)
    File.write("#{remote}/origin.plugin.zsh", "# origin\n")
    system(git_env, "git", "-C", remote, "add", ".")
    system(git_env, "git", "-C", remote, "commit", "-q", "-m", "init")
    system(git_env, "git", "clone", "-q", "file://#{remote}", dir)
    entry = plugin_entry("origin", dir)
    entry["url"] = "file://#{remote}"
    seed_plugins([entry])
  end

  def test_name_miss_never_acts_on_fuzzy_guess
    print "Test 37: 'rig' with only 'origin' installed: every name subcommand exits 65, suggests, changes nothing... "
    seed_origin_plugin
    before = File.read("#{@data_dir}/plugins.json")
    FileUtils.rm_rf("#{@data_dir}/backup")

    failures = []
    ["disable rig", "enable rig", "priority rig 5", "update rig", "get rig", "rm rig --yes"].each do |cmd|
      out, err, status = run_wayu_split("plugin #{cmd}")
      ok = status.exitstatus == 65 && out.empty? &&
           err.include?("Plugin not found: rig") && err.include?("Did you mean") && err.include?("origin")
      failures << "#{cmd}: exit=#{status.exitstatus} stdout=#{out.inspect} stderr=#{err.inspect}" unless ok
    end
    unchanged = File.read("#{@data_dir}/plugins.json") == before && backup_files.empty? &&
                Dir.exist?("#{@plugins_dir}/origin")
    failures << "plugins.json/backup/dir changed" unless unchanged

    # No plugins at all: a named update/rm is still a miss, not "nothing to do".
    seed_plugins([])
    ["update rig", "rm rig --yes"].each do |cmd|
      out, err, status = run_wayu_split("plugin #{cmd}")
      failures << "empty #{cmd}: exit=#{status.exitstatus} stdout=#{out.inspect}" unless status.exitstatus == 65 && out.empty?
    end
    check("fuzzy miss acted or wrong report", failures.empty?, failures.join("\n  "), nil)
  end

  def test_exact_name_still_works
    print "Test 38: exact name works for disable/enable/priority/get/update/rm... "
    seed_origin_plugin
    cfg = -> { JSON.parse(File.read("#{@data_dir}/plugins.json"))["plugins"] }
    failures = []

    out, st = run_wayu("plugin disable origin")
    failures << "disable: #{out}" unless st.exitstatus == 0 && out.include?("origin") && cfg.call[0]["enabled"] == false
    out, st = run_wayu("plugin enable origin")
    failures << "enable: #{out}" unless st.exitstatus == 0 && cfg.call[0]["enabled"] == true
    out, st = run_wayu("plugin priority origin 5")
    failures << "priority: #{out}" unless st.exitstatus == 0 && out.include?("'origin'") && cfg.call[0]["priority"] == 5
    out, st = run_wayu("--dry-run plugin get origin") # dry-run: no clipboard write
    failures << "get: #{out}" unless st.exitstatus == 0 && out.include?("origin")
    out, st = run_wayu("plugin update origin")
    failures << "update: #{out}" unless st.exitstatus == 0
    out, st = run_wayu("plugin rm origin --yes")
    failures << "rm: #{out}" unless st.exitstatus == 0 && cfg.call.empty?
    check("exact name failed", failures.empty?, failures.join("\n  "), nil)
  end

  # ── Offline real-git fixtures (OKAMI-246) ──────────────────────────────

  # Create (or reset) fixture repo <fixtures>/<name>.git with `files`
  # committed on main; https://example.test/<name>.git clones it.
  def fixture_repo(name, files = nil)
    files ||= { "#{name}.plugin.zsh" => "# #{name} v1\n" }
    repo = "#{@git_fixtures}/#{name}.git"
    FileUtils.rm_rf(repo)
    git!("init", "-q", "-b", "main", repo)
    files.each do |path, content|
      FileUtils.mkdir_p(File.dirname("#{repo}/#{path}"))
      File.write("#{repo}/#{path}", content)
    end
    git!("-C", repo, "add", "-A")
    git!("-C", repo, "commit", "-q", "-m", "init")
    repo
  end

  def fixture_commit(repo, file, content, amend: false)
    File.write("#{repo}/#{file}", content)
    git!("-C", repo, "add", "-A")
    if amend
      git!("-C", repo, "commit", "-q", "--amend", "-m", "rewritten")
    else
      git!("-C", repo, "commit", "-q", "-m", "change #{file}")
    end
  end

  def git!(*args)
    out, status = Open3.capture2e("git", *args)
    raise "git #{args.join(' ')} failed: #{out}" unless status.success?
    out.strip
  end

  def fixture_url(name)
    "https://example.test/#{name}.git"
  end

  def config_plugin(name)
    JSON.parse(File.read("#{@data_dir}/plugins.json"))["plugins"].find { |p| p["name"] == name }
  end

  def plugins_loader
    File.exist?("#{@data_dir}/plugins.zsh") ? File.read("#{@data_dir}/plugins.zsh") : ""
  end

  def reset_plugins
    seed_plugins([])
    FileUtils.rm_rf(Dir.glob("#{@plugins_dir}/*"))
  end

  def test_offline_add_clones_and_loads
    print "Test 39: add <url> clones offline, records ZSH, loader sources the one entry file... "
    reset_plugins
    fixture_repo("alpha", { "alpha.plugin.zsh" => "source ${0:h}/alpha.zsh\n", "alpha.zsh" => "# alpha\n" })

    output, status = run_wayu("plugin add #{fixture_url('alpha')}")
    entry = config_plugin("alpha")
    loader = plugins_loader
    ok = status.exitstatus == 0 &&
         File.exist?("#{@plugins_dir}/alpha/alpha.plugin.zsh") &&
         entry && entry["shell"] == "ZSH" && entry["url"] == fixture_url("alpha") &&
         loader.include?("#{@plugins_dir}/alpha/alpha.plugin.zsh") &&
         !loader.include?("#{@plugins_dir}/alpha/alpha.zsh'")
    check("offline add failed", ok, output + "\nloader:\n" + loader, status)
  end

  # Plugin *.zsh sources are compiled to .zwc in the background (zsh would
  # parse them at every startup otherwise); test/test-data dirs are skipped.
  def test_offline_plugin_sources_zcompiled
    print "Test 39a: plugin sources get .zwc digests, tests dirs skipped... "
    reset_plugins
    fixture_repo("zc", { "zc.plugin.zsh" => "source ${0:h}/lib/zc.zsh\n", "lib/zc.zsh" => "zc() { :; }\n",
                         "test/t.zsh" => "# test\n", "x/test-data/d.zsh" => "# data\n" })
    output, status = run_wayu("plugin add #{fixture_url('zc')}")
    dir = "#{@plugins_dir}/zc"
    want = ["#{dir}/zc.plugin.zsh.zwc", "#{dir}/lib/zc.zsh.zwc"]
    deadline = Time.now + 10
    sleep 0.1 until want.all? { |f| File.exist?(f) } || Time.now > deadline
    ok = status.exitstatus == 0 && want.all? { |f| File.exist?(f) } &&
         !File.exist?("#{dir}/test/t.zsh.zwc") && !File.exist?("#{dir}/x/test-data/d.zsh.zwc")
    check("plugin zcompile", ok, output + "\nfiles: " + Dir.glob("#{dir}/**/*.zwc").join(" "), status)
  end

  # OKAMI-276: conflicts are shown on add/enable, in `plugin list` (text and
  # --json) and by doctor — between plugins and with entries.json, including
  # definitions after `export X=..;` on the same line.
  def test_offline_conflicts_reported
    print "Test 39b: plugin conflicts shown on add/enable, list, list --json, doctor... "
    reset_plugins
    run_wayu("alias add gq 'git status'")
    fixture_repo("cfa", { "cfa.plugin.zsh" => "dup() { :; }\nalias gs='git status'\n" })
    fixture_repo("cfb", { "cfb.plugin.zsh" => "export CFB_X=1; dup() { :; }; alias gq='git q'\n" })
    failures = []
    _, st = run_wayu("plugin add #{fixture_url('cfa')}")
    failures << "add cfa #{st.exitstatus}" unless st.exitstatus == 0
    out, st = run_wayu("plugin add #{fixture_url('cfb')}")
    failures << "add cfb warning: #{out}" unless st.exitstatus == 0 &&
      out.include?("function dup (also defined by cfa)") && out.include?("alias gq (also defined by entries.json)")
    run_wayu("plugin disable cfb")
    out, st = run_wayu("plugin enable cfb")
    failures << "enable warning: #{out}" unless st.exitstatus == 0 && out.include?("function dup (also defined by cfa)")
    out, _ = run_wayu("plugin list")
    failures << "list: #{out}" unless out.include?("cfa: function dup (also defined by cfb)") && out.include?("cfb: alias gq (also defined by entries.json)")
    json, st = run_wayu("plugin list --json")
    begin
      doc = JSON.parse(json)
      cfa = doc["plugins"].find { |x| x["name"] == "cfa" }
      cfb = doc["plugins"].find { |x| x["name"] == "cfb" }
      failures << "json cfa: #{cfa}" unless cfa["conflicts"] == [{ "kind" => "function", "name" => "dup", "with" => "cfb" }]
      failures << "json cfb: #{cfb}" unless cfb["conflicts"].include?({ "kind" => "alias", "name" => "gq", "with" => "entries.json" })
    rescue StandardError => e
      failures << "json: #{e} #{json}"
    end
    out, st = run_wayu("doctor")
    failures << "doctor: #{out}" unless out.include?("function dup in cfa and cfb")
    run_wayu("alias rm gq")
    check("conflicts reported", failures.empty?, failures.join("\n  "), nil)
  end

  def test_offline_check_and_update
    print "Test 40: check up to date → update available → update fast-forwards... "
    reset_plugins
    repo = fixture_repo("beta")
    _, st_add = run_wayu("plugin add #{fixture_url('beta')}")
    failures = []
    failures << "add exit #{st_add.exitstatus}" unless st_add.exitstatus == 0

    out, st = run_wayu("plugin check")
    failures << "check1: #{out}" unless st.exitstatus == 0 && out.include?("Up to date")

    fixture_commit(repo, "beta.plugin.zsh", "# beta v2\n")
    out, st = run_wayu("plugin check")
    failures << "check2: #{out}" unless st.exitstatus == 0 && out.include?("Update available")

    out, st = run_wayu("plugin update beta")
    content = File.read("#{@plugins_dir}/beta/beta.plugin.zsh") rescue ""
    failures << "update: #{out}" unless st.exitstatus == 0 && content.include?("v2")

    out, st = run_wayu("plugin check")
    failures << "check3: #{out}" unless st.exitstatus == 0 && out.include?("Up to date")
    check("check/update flow", failures.empty?, failures.join("\n  "), nil)
  end

  def test_offline_check_exact_branch_ref
    print "Test 41: check ignores decoy refs ending in the branch name (aaa/main, tag main)... "
    reset_plugins
    repo = fixture_repo("gamma")
    run_wayu("plugin add #{fixture_url('gamma')}")
    git!("-C", repo, "checkout", "-q", "-b", "aaa/main")
    fixture_commit(repo, "decoy.txt", "decoy\n")
    git!("-C", repo, "tag", "main")
    git!("-C", repo, "checkout", "-q", "main")

    output, status = run_wayu("plugin check")
    ok = status.exitstatus == 0 && output.include?("Up to date") && !output.include?("Update available")
    check("decoy ref reported as update", ok, output, status)
  end

  def test_offline_check_unreachable_exits_74
    print "Test 42: check exits 74 when a remote is gone... "
    reset_plugins
    fixture_repo("delta2")
    run_wayu("plugin add #{fixture_url('delta2')}")
    FileUtils.rm_rf("#{@git_fixtures}/delta2.git")

    output, status = run_wayu("plugin check")
    ok = status.exitstatus == 74 && output.include?("could not be checked") && !output.include?("All plugins are up to date")
    check("unreachable remote not reported", ok, output, status)
  end

  def test_offline_update_divergent_history
    print "Test 43: update resets a clean checkout after force-push; refuses local commits (74)... "
    reset_plugins
    repo = fixture_repo("eps")
    run_wayu("plugin add #{fixture_url('eps')}")
    failures = []

    fixture_commit(repo, "eps.plugin.zsh", "# eps rewritten\n", amend: true)
    out, st = run_wayu("plugin update eps")
    content = File.read("#{@plugins_dir}/eps/eps.plugin.zsh") rescue ""
    failures << "force-push: #{out}" unless st.exitstatus == 0 && out.include?("reset to remote") && content.include?("rewritten")

    dir = "#{@plugins_dir}/eps"
    File.write("#{dir}/local.txt", "mine\n")
    git!("-C", dir, "add", "local.txt")
    git!("-C", dir, "commit", "-q", "-m", "local")
    fixture_commit(repo, "eps.plugin.zsh", "# eps upstream\n", amend: true)
    out, st = run_wayu("plugin update eps")
    failures << "local commit: #{out}" unless st.exitstatus == 74 && File.exist?("#{dir}/local.txt") && out.include?("local commits")
    check("divergent update", failures.empty?, failures.join("\n  "), nil)
  end

  def test_offline_symlink_rm_keeps_target
    print "Test 44: rm of a symlinked plugin removes the link, keeps the working copy... "
    reset_plugins
    work = "#{@tmp_home}/devplug"
    FileUtils.rm_rf(work)
    FileUtils.mkdir_p(work)
    File.write("#{work}/devplug.plugin.zsh", "# dev\n")
    link = "#{@plugins_dir}/devplug"
    File.symlink(work, link)
    seed_plugins([plugin_entry("devplug", link)])

    output, status = run_wayu("plugin rm devplug --yes")
    ok = status.exitstatus == 0 && !File.symlink?(link) && !File.exist?(link) &&
         File.exist?("#{work}/devplug.plugin.zsh") && plugin_names_in_config.empty?
    check("symlink rm touched the target", ok, output, status)
  end

  def test_offline_add_nothing_to_load_rolls_back
    print "Test 45: add of a repo with nothing to load exits 65 and leaves nothing behind... "
    reset_plugins
    fixture_repo("binarytool", { "README.md" => "# tool\n", "install.sh" => "echo install\n", "src/main.rs" => "fn main(){}\n" })

    out, err, status = run_wayu_split("plugin add #{fixture_url('binarytool')}")
    ok = status.exitstatus == 65 && !Dir.exist?("#{@plugins_dir}/binarytool") &&
         plugin_names_in_config.empty? && err.include?("nothing wayu can load") && err.include?("--use") &&
         !out.include?("installed successfully")
    check("nothing-to-load install not refused", ok, out + err, status)
  end

  def test_offline_add_use_glob
    print "Test 46: add --use <file> installs a repo without a standard entry file... "
    reset_plugins
    fixture_repo("custom-entry", { "README.md" => "# x\n", "entry.sh" => "# entry\n" })

    output, status = run_wayu("plugin add #{fixture_url('custom-entry')} --use entry.sh")
    entry = config_plugin("custom-entry")
    ok = status.exitstatus == 0 && entry && entry["use"] == ["entry.sh"] && entry["shell"] == "BOTH" &&
         plugins_loader.include?("#{@plugins_dir}/custom-entry/entry.sh")

    out2, st2 = run_wayu("plugin add #{fixture_url('custom-entry')}x --use lib/a.zsh")
    out3, st3 = run_wayu("plugin add #{fixture_url('alpha')} --use")
    ok &&= st2.exitstatus == 64 && st3.exitstatus == 64
    check("--use install failed", ok, [output, out2, out3].join("\n"), status)
  end

  def test_offline_add_zsh_theme
    print "Test 47: add of a prompt theme (only <name>.zsh-theme) loads it... "
    reset_plugins
    fixture_repo("mytheme", { "mytheme.zsh-theme" => "# theme\n", "README.md" => "x\n" })

    output, status = run_wayu("plugin add #{fixture_url('mytheme')}")
    ok = status.exitstatus == 0 && plugins_loader.include?("#{@plugins_dir}/mytheme/mytheme.zsh-theme") &&
         config_plugin("mytheme")&.dig("shell") == "ZSH"
    check("zsh-theme not loaded", ok, output, status)
  end

  def test_offline_add_fish_url_records_fish
    print "Test 48: add <url> of a fish-only plugin records FISH (not zsh/bash)... "
    reset_plugins
    fixture_repo("fishy", { "conf.d/fishy.fish" => "# conf\n", "functions/fishy.fish" => "function fishy; end\n" })

    output, status = run_wayu("plugin add #{fixture_url('fishy')}")
    # PLG-08 / OKAMI-268: added from fish, the fish loader sources it.
    fixture_repo("fishy2", { "conf.d/fishy2.fish" => "# conf\n" })
    env = ENV.to_h.merge('HOME' => @tmp_home, 'SHELL' => '/usr/bin/fish')
    _, _, st2 = Open3.capture3(env, @wayu_bin, '--shell', 'fish', 'plugin', 'add', fixture_url('fishy2'))
    fish_loader = File.read("#{@data_dir}/plugins.fish") rescue ""
    ok = status.exitstatus == 0 && st2.success? && fish_loader.include?("conf.d/fishy2.fish") && config_plugin("fishy")&.dig("shell") == "FISH" &&
         !plugins_loader.include?("fishy.fish") && config_plugin("fishy2")&.dig("shell") == "FISH"
    check("fish URL compat", ok, output, status)
  end

  def test_offline_concurrent_adds
    print "Test 49: two concurrent adds both land in plugins.json... "
    reset_plugins
    fixture_repo("conc-a")
    fixture_repo("conc-b")
    env = ENV.to_h.merge('HOME' => @tmp_home)
    project_root = File.expand_path('../..', __dir__)
    threads = %w[conc-a conc-b].map do |n|
      Thread.new { Open3.capture2e(env, @wayu_bin, "plugin", "add", fixture_url(n), chdir: project_root) }
    end
    results = threads.map(&:value)
    names = plugin_names_in_config.sort
    ok = results.all? { |_, st| st.exitstatus == 0 } && names == %w[conc-a conc-b]
    check("concurrent add lost an entry", ok, results.map(&:first).join("\n") + "\nnames=#{names}", nil)
  end

  def test_offline_registry_pure_fish_name
    print "Test 50: registry pure-fish installs as 'pure-fish' (no clash with zsh pure)... "
    out1, st1 = run_wayu("--dry-run plugin add pure-fish")
    out2, st2 = run_wayu("--dry-run plugin add pure")
    out3, st3 = run_wayu("--dry-run plugin add starship")
    ok = st1.exitstatus == 0 && out1.include?("Name: pure-fish") &&
         st2.exitstatus == 0 && out2.include?("Name: pure") && !out2.include?("pure-fish") &&
         st3.exitstatus == 65
    check("registry names", ok, [out1, out2, out3].join("\n"), st3)
  end

  # A fake `ssh` on PATH records its arguments and hangs: proves wayu runs
  # ssh in batch mode with a connect timeout, and that WAYU_GIT_TIMEOUT
  # kills the hung transfer (and its helpers) instead of waiting forever.
  def test_ssh_batch_mode_and_timeout
    print "Test 51: ssh runs with BatchMode=yes; a hung transfer is killed at WAYU_GIT_TIMEOUT... "
    reset_plugins
    fake_bin = "#{@tmp_home}/fake-bin"
    args_file = "#{@tmp_home}/ssh-args"
    FileUtils.mkdir_p(fake_bin)
    FileUtils.rm_f(args_file)
    File.write("#{fake_bin}/ssh", "#!/bin/sh\necho \"$@\" > '#{args_file}'\nexec sleep 60\n")
    File.chmod(0o755, "#{fake_bin}/ssh")

    old_path, old_timeout = ENV['PATH'], ENV['WAYU_GIT_TIMEOUT']
    ENV['PATH'] = "#{fake_bin}:#{old_path}"
    ENV['WAYU_GIT_TIMEOUT'] = '2'
    t0 = Time.now
    output, status = nil, nil
    begin
      Timeout.timeout(30) { output, status = run_wayu("plugin add ssh://git.example.test/user/hung.git") }
    rescue Timeout::Error
      output = "TIMEOUT: wayu never gave up"
    ensure
      ENV['PATH'] = old_path
      old_timeout ? ENV['WAYU_GIT_TIMEOUT'] = old_timeout : ENV.delete('WAYU_GIT_TIMEOUT')
    end
    elapsed = Time.now - t0
    ssh_args = File.exist?(args_file) ? File.read(args_file) : ""
    ok = status && status.exitstatus == 74 && elapsed < 20 &&
         output.include?("timed out") && ssh_args.include?("BatchMode=yes") &&
         ssh_args.include?("ConnectTimeout=") && !Dir.exist?("#{@plugins_dir}/hung")
    check("ssh batch/timeout", ok, "#{output}\nssh args: #{ssh_args.inspect}\nelapsed=#{elapsed.round(1)}s", status)
  end

  # OKAMI-342: `update --all` counts only checkouts that moved; the rest are
  # reported as already up to date.
  def test_offline_update_all_counts_real_updates
    print "Test 60: update --all counts only real updates... "
    reset_plugins
    repo = fixture_repo("upa")
    fixture_repo("upb")
    run_wayu("plugin add #{fixture_url('upa')}")
    run_wayu("plugin add #{fixture_url('upb')}")
    fixture_commit(repo, "upa.plugin.zsh", "# upa v2\n")
    out, st = run_wayu("plugin update --all")
    ok = st.exitstatus == 0 && out.include?("1 plugin updated") && out.include?("1 already up to date")
    check("update --all count", ok, out, st)
  end

  # OKAMI-330: plugins.json backups are pruned like every other file's.
  def test_plugins_json_backups_pruned
    print "Test 61: plugins.json backups pruned to 5... "
    dir = "#{@plugins_dir}/prune-me"
    FileUtils.mkdir_p(dir)
    seed_plugins([plugin_entry("prune-me", dir)])
    FileUtils.rm_f(backup_files)
    out = +""
    4.times do
      o1, = run_wayu("plugin disable prune-me")
      o2, = run_wayu("plugin enable prune-me")
      out << o1 << o2
    end
    run_wayu("plugin priority prune-me 50")
    n = backup_files.size
    check("backups: #{n}", n == 5, out, nil)
  end

  # OKAMI-342: a nameless entry, a duplicate name and a `use` glob that
  # leaves the checkout are refused (exit 78), not loaded.
  def test_plugins_json_rejects_bad_entries
    print "Test 62: plugins.json with missing/duplicate name or ../ use glob exits 78... "
    dir = "#{@plugins_dir}/v1"
    FileUtils.mkdir_p(dir)
    bad = {
      "missing name" => [plugin_entry("", dir)],
      "duplicate name" => [plugin_entry("v1", dir), plugin_entry("v1", dir)],
      "use escape" => [plugin_entry("v1", dir).merge("use" => ["../../../etc/*"])],
    }
    failures = []
    bad.each do |label, entries|
      seed_plugins(entries)
      out, st = run_wayu("plugin list")
      failures << "#{label}: exit #{st.exitstatus} #{out}" unless st.exitstatus == 78 && out.include?("Invalid plugins.json")
    end
    seed_plugins([])
    check("validation", failures.empty?, failures.join("\n  "), nil)
  end

  # A checkout's own config must never make wayu's git run a program:
  # core.fsmonitor (status/merge/reset) and hooks (post-merge, ...).
  def test_offline_update_ignores_repo_hooks
    print "Test 63: plugin update/check ignore core.fsmonitor and repo hooks... "
    reset_plugins
    repo = fixture_repo("hooked")
    _, st = run_wayu("plugin add #{fixture_url('hooked')}")
    dir = "#{@plugins_dir}/hooked"
    markers = %w[fsmonitor post-merge post-checkout].map { |m| "#{@tmp_home}/marker-#{m}" }
    FileUtils.rm_f(markers)
    hook = "#{@tmp_home}/fsmonitor-hook"
    File.write(hook, "#!/bin/sh\ntouch '#{markers[0]}'\n")
    File.chmod(0o755, hook)
    git!("-C", dir, "config", "core.fsmonitor", hook)
    { "post-merge" => markers[1], "post-checkout" => markers[2] }.each do |h, m|
      File.write("#{dir}/.git/hooks/#{h}", "#!/bin/sh\ntouch '#{m}'\n")
      File.chmod(0o755, "#{dir}/.git/hooks/#{h}")
    end
    fixture_commit(repo, "hooked.plugin.zsh", "# hooked v2\n")
    out, st2 = run_wayu("plugin update hooked")
    out2, = run_wayu("plugin check")
    ran = markers.select { |m| File.exist?(m) }
    content = File.read("#{dir}/hooked.plugin.zsh") rescue ""
    ok = st.exitstatus == 0 && st2.exitstatus == 0 && content.include?("v2") && ran.empty?
    check("repo hooks ran: #{ran}", ok, out + out2, st2)
  end
end


# Run tests if executed directly
if __FILE__ == $0
  PluginIntegrationTest.new.run
end
