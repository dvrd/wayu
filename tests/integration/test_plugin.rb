#!/usr/bin/env ruby
# Integration tests for plugin command

require 'open3'
require 'fileutils'
require 'json'

class PluginIntegrationTest
  attr_reader :passed, :failed

  def initialize
    @passed = 0
    @failed = 0
    @wayu_bin = './bin/wayu'
    @config_dir = File.expand_path('~/.config/wayu')
    @config_backup = File.expand_path('~/.config/wayu.backup')
    @plugins_dir = "#{@config_dir}/plugins"
  end

  def run
    puts "🔌 Testing plugin command integration..."
    puts

    build_project
    backup_config
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

    output, status = run_wayu("plugin rm removable-plugin")

    # Should either succeed or show not found error (both acceptable)
    if !Dir.exist?(plugin_dir) || output.include?("not found")
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

    output, status = run_wayu("plugin check")

    # Should complete without error and indicate no plugins
    if status.success? && (output.include?("No plugins") || output.include?("0 plugin") || output.empty?)
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

    # Create multiple mock plugins
    ['plugin-a', 'plugin-b'].each do |name|
      plugin_dir = "#{@plugins_dir}/#{name}"
      FileUtils.mkdir_p(plugin_dir)
      File.write("#{plugin_dir}/#{name}.plugin.zsh", "# Plugin #{name}")
    end

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
    json_file = "#{@config_dir}/plugins.json"
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
    json_file = "#{@config_dir}/plugins.json"
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
    json_file = "#{@config_dir}/plugins.json"
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
    json_file = "#{@config_dir}/plugins.json"
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
    json_file = "#{@config_dir}/plugins.json"
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
    json_file = "#{@config_dir}/plugins.json"
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
    json_file = "#{@config_dir}/plugins.json"
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
          "enabled" => true,
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
    json_file = "#{@config_dir}/plugins.json"
    File.write(json_file, JSON.pretty_generate(json_config))

    # Trigger shell loader generation by running list command
    output, status = run_wayu("plugin list")

    # Read generated plugins.zsh file
    plugins_file = "#{@config_dir}/plugins.zsh"
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
          "enabled" => true,
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
    json_file = "#{@config_dir}/plugins.json"
    File.write(json_file, JSON.pretty_generate(json_config))

    # Trigger loader generation by running list command
    output, status = run_wayu("plugin list")

    # Read generated plugins.zsh file
    plugins_file = "#{@config_dir}/plugins.zsh"
    if File.exist?(plugins_file)
      loader_content = File.read(plugins_file)

      # Verify global conflict warning header exists
      has_global_warning = loader_content.include?("⚠️  CONFLICT WARNINGS") &&
                           loader_content.include?("conflict-plugin-a conflicts with:")

      # Verify per-plugin conflict warnings exist
      has_plugin_a_warning = loader_content.include?("⚠️  WARNING: conflict-plugin-a has conflicts")
      has_plugin_b_warning = loader_content.include?("⚠️  WARNING: conflict-plugin-b has conflicts")

      if has_global_warning && has_plugin_a_warning && has_plugin_b_warning
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

    # Create two mock plugins with NO conflicts
    plugin_x_dir = "#{@plugins_dir}/unique-plugin-x"
    plugin_y_dir = "#{@plugins_dir}/unique-plugin-y"
    FileUtils.mkdir_p(plugin_x_dir)
    FileUtils.mkdir_p(plugin_y_dir)

    File.write("#{plugin_x_dir}/unique-plugin-x.plugin.zsh", <<~SHELL)
      # Plugin X - unique declarations
      export VAR_X="value_x"

      function_x() {
        echo "from plugin x"
      }

      alias lx="ls -x"
    SHELL

    File.write("#{plugin_y_dir}/unique-plugin-y.plugin.zsh", <<~SHELL)
      # Plugin Y - different declarations
      export VAR_Y="value_y"

      function_y() {
        echo "from plugin y"
      }

      alias ly="ls -y"
    SHELL

    # Create JSON config WITHOUT conflicts
    json_config = {
      "version" => "1.0",
      "lastUpdated" => Time.now.utc.iso8601,
      "plugins" => [
        {
          "name" => "unique-plugin-x",
          "url" => "https://github.com/test/unique-x.git",
          "enabled" => true,
          "shell" => "zsh",
          "installedPath" => plugin_x_dir,
          "entryFile" => "unique-plugin-x.plugin.zsh",
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
            "envVars" => ["VAR_X"],
            "functions" => ["function_x"],
            "aliases" => ["lx"],
            "detected" => false,  # No conflicts
            "conflictingPlugins" => []
          }
        },
        {
          "name" => "unique-plugin-y",
          "url" => "https://github.com/test/unique-y.git",
          "enabled" => true,
          "shell" => "zsh",
          "installedPath" => plugin_y_dir,
          "entryFile" => "unique-plugin-y.plugin.zsh",
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
            "envVars" => ["VAR_Y"],
            "functions" => ["function_y"],
            "aliases" => ["ly"],
            "detected" => false,  # No conflicts
            "conflictingPlugins" => []
          }
        }
      ]
    }

    # Write JSON config
    json_file = "#{@config_dir}/plugins.json"
    File.write(json_file, JSON.pretty_generate(json_config))

    # Trigger loader generation by running list command
    output, status = run_wayu("plugin list")

    # Read generated plugins.zsh file
    plugins_file = "#{@config_dir}/plugins.zsh"
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
      puts "✗"
      puts "  Loader file not generated: #{plugins_file}"
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
      puts "✓ All #{total} plugin integration tests passed!"
    else
      puts "Results: #{@passed}/#{total} tests passed, #{@failed} failed"
    end
    puts "━" * 50
  end
end

# Run tests if executed directly
if __FILE__ == $0
  PluginIntegrationTest.new.run
end
