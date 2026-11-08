package wayu
import "core:fmt"
import "core:os"
import "core:strings"
import "core:slice"
import "core:sync"
import "core:strconv"
import "core:encoding/json"
handle_plugin_check :: proc(args: []string) {
	// Hold the config lock across read-modify-write of plugins.json so
	// concurrent wayu runs cannot drop each other's changes.
	config_lock_acquire_or_exit()
	defer config_lock_release()

	// Read plugin configuration
	config, ok := read_plugin_config_json()
	if !ok {
		os.exit(EXIT_CONFIG)
	}
	defer cleanup_plugin_config_json(&config)

	// Handle empty plugin list (non-error case)
	if len(config.plugins) == 0 {
		print_info("No plugins installed")
		fmt.println()
		fmt.println("Run 'wayu plugin add <name>' to install a plugin")
		return
	}

	// Display header
	print_header("Checking Plugin Updates", EMOJI_COMMAND)
	fmt.println()

	updates_available := false
	check_count := 0
	failed_count := 0

	// Check each enabled plugin
	for &plugin in config.plugins {
		// Skip disabled plugins
		if !plugin.enabled {
			continue
		}

		check_count += 1
		fmt.printfln("Checking %s...", plugin.name)

		if pinned, ref := plugin_pinned_ref(&plugin); pinned {
			// A commit pin is an integrity claim: verify the checkout still
			// sits on it (someone may have pulled/checked out by hand).
			if problem := plugin_pinned_commit_problem(&plugin); problem != "" {
				print_warning("  ⚠ %s", problem)
				failed_count += 1
				continue
			}
			print_info("  ⚓ Pinned to %s (skipped)", ref)
			continue
		}

		// Fetch remote commit SHA
		// NOTE: get_remote_commit returns an allocated string — must delete explicitly.
		// defer inside a loop defers to function exit (not iteration end), so we use
		// a plain delete at the bottom of the loop body instead.
		remote_commit := get_remote_commit(plugin.url, plugin.git.branch)
		if remote_commit == "" {
			print_warning("  ⚠ Failed to check remote (network error, invalid URL or missing branch)")
			failed_count += 1
			continue
		}

		// Update metadata with remote commit and timestamp
		delete(plugin.git.remote_commit)  // Clean up old value
		plugin.git.remote_commit = strings.clone(remote_commit)

		delete(plugin.git.last_checked)  // Clean up old timestamp
		plugin.git.last_checked = get_iso8601_timestamp()  // ALLOCATED

		// Compare local vs remote commits
		if !git_commits_match(plugin.git.commit, remote_commit) {
			// Truncate to 7 chars for display
			local_short := plugin.git.commit[0:min(7, len(plugin.git.commit))]
			remote_short := remote_commit[0:min(7, len(remote_commit))]

			print_success("  ↑ Update available: %s → %s", local_short, remote_short)
			updates_available = true
		} else {
			print_info("  ✓ Up to date")
		}

		delete(remote_commit)  // Free per-iteration — not deferred (see note above)
	}

	fmt.println()

	// No enabled plugins to check
	if check_count == 0 {
		print_info("No enabled plugins to check")
		fmt.println()
		print_info("Enable plugins with: wayu --tui")
		return
	}

	// Save updated metadata (last_checked timestamps)
	if !wayu.dry_run {
		if !write_plugin_config_json(&config) {
			print_error_simple("Failed to save plugin metadata")
			os.exit(EXIT_CONFIG)
		}
	} else {
		print_info("[DRY RUN] Would save updated metadata")
	}

	// Display summary
	if updates_available {
		fmt.println()
		print_info("Updates available! Run one of:")
		fmt.println("  wayu plugin update <name>      # Update specific plugin")
		fmt.println("  wayu plugin update --all       # Update all plugins")
	}

	// Never print the all-clear when some plugins could not be checked:
	// scripts rely on the exit code to tell "up to date" from "offline".
	if failed_count > 0 {
		fmt.println()
		print_error_simple("%d plugin(s) could not be checked", failed_count)
		os.exit(EXIT_IOERR)
	}

	if !updates_available {
		print_success("All plugins are up to date!")
	}
}

// For a plugin pinned to a commit, report (temp string) when its checkout
// is not on that commit; "" when it is, or when it is not commit-pinned.
plugin_pinned_commit_problem :: proc(plugin: ^PluginMetadata) -> string {
	if plugin.git.ref_type != .Commit {
		return ""
	}
	want := len(plugin.git.pinned_ref) > 0 ? plugin.git.pinned_ref : plugin.git.commit
	if len(want) == 0 || len(plugin.installed_path) == 0 {
		return ""
	}
	head := capture_command([]string{"git", "-C", plugin.installed_path, "rev-parse", "HEAD"})
	defer delete(head)
	if len(head) == 0 {
		return fmt.tprintf("Cannot read the checkout of pinned plugin at %s", plugin.installed_path)
	}
	if !git_commits_match(head, want) {
		return fmt.tprintf("Checkout is at %s but the plugin is pinned to %s", head[:min(12, len(head))], want)
	}
	return ""
}

// Update one plugin checkout and refresh its metadata. Prints progress with
// `indent`; returns false on failure (git's stderr is shown). In dry-run
// nothing is executed and the caller must not count it as updated.
plugin_update_one :: proc(plugin: ^PluginMetadata, indent: string) -> bool {
	old_commit := strings.clone(plugin.git.commit)
	defer delete(old_commit)

	result, err_text := git_update(plugin.installed_path, plugin.git.branch)
	defer delete(err_text)

	if result == .Failed {
		print_warning("%s⚠ Failed to update %s", indent, plugin.name)
		for line in strings.split_lines(err_text, context.temp_allocator) {
			if len(strings.trim_space(line)) > 0 {
				fmt.eprintfln("%s  %s", indent, line)
			}
		}
		return false
	}

	plugin_refresh_git_metadata(plugin)

	old_short := old_commit[:min(7, len(old_commit))]
	new_short := plugin.git.commit[:min(7, len(plugin.git.commit))]
	if git_commits_match(old_commit, plugin.git.commit) {
		print_success("%s✓ Already up to date (%s)", indent, new_short)
	} else if result == .Reset {
		print_success("%s✓ Updated %s → %s (upstream history was rewritten; reset to remote)", indent, old_short, new_short)
	} else {
		print_success("%s✓ Updated %s → %s", indent, old_short, new_short)
	}
	return true
}

// Handle plugin update command - update plugins
// Supports both single plugin and --all flag
// CLI-only command (no interactive mode)
handle_plugin_update :: proc(args: []string) {
	// Require explicit argument (plugin name or --all)
	if len(args) == 0 {
		print_error("Missing required argument: plugin name or --all")
		fmt.println()
		fmt.println("Usage:")
		fmt.println("  wayu plugin update <name>      # Update specific plugin")
		fmt.println("  wayu plugin update --all       # Update all plugins")
		fmt.println()
		fmt.printfln("%sExample:%s", get_muted(), RESET)
		fmt.printfln("  %swayu plugin update zsh-autosuggestions%s", get_muted(), RESET)
		os.exit(EXIT_USAGE)
	}

	update_all := args[0] == "--all" || args[0] == "-a"

	// Hold the config lock across read-modify-write of plugins.json so
	// concurrent wayu runs cannot drop each other's changes.
	config_lock_acquire_or_exit()
	defer config_lock_release()

	// Read plugin configuration
	config, ok := read_plugin_config_json()
	if !ok {
		os.exit(EXIT_CONFIG)
	}
	defer cleanup_plugin_config_json(&config)

	// Handle empty plugin list (a named update falls through to the miss report)
	if len(config.plugins) == 0 && update_all {
		print_info("No plugins installed")
		fmt.println()
		fmt.println("Run 'wayu plugin add <name>' to install a plugin")
		return
	}

	// Exact name only; a miss exits before anything is printed on stdout.
	plugin_ptr: ^PluginMetadata
	if !update_all {
		plugin_ptr = find_plugin_or_exit(&config, args[0])
	}

	// Display header
	if update_all {
		print_header("Updating All Plugins", EMOJI_COMMAND)
	} else {
		print_header("Updating Plugin", EMOJI_COMMAND)
	}
	fmt.println()

	updated_count := 0
	failed_count := 0

	// Update specific plugin
	if !update_all {
		if pinned, ref := plugin_pinned_ref(plugin_ptr); pinned {
			print_info("Plugin '%s' is pinned to %s — not updating", plugin_ptr.name, ref)
			fmt.println("Unpin it in plugins.json to follow a branch again")
			return
		}

		if wayu.dry_run {
			print_info("[DRY RUN] Would update %s (%s)", plugin_ptr.name, plugin_ptr.installed_path)
			return
		}

		print_info("Updating %s...", plugin_ptr.name)
		if !plugin_update_one(plugin_ptr, "  ") {
			print_error_simple("Failed to update plugin '%s'", plugin_ptr.name)
			os.exit(EXIT_IOERR)
		}
		updated_count = 1
	} else {
		would_update := 0

		// Update all plugins
		for &plugin in config.plugins {
			// Skip disabled plugins
			if !plugin.enabled {
				continue
			}

			if pinned, ref := plugin_pinned_ref(&plugin); pinned {
				print_info("%s: ⚓ pinned to %s (skipped)", plugin.name, ref)
				continue
			}

			if wayu.dry_run {
				print_info("[DRY RUN] Would update %s", plugin.name)
				would_update += 1
				continue
			}

			print_info("Updating %s...", plugin.name)
			if !plugin_update_one(&plugin, "  ") {
				failed_count += 1
				continue
			}
			updated_count += 1
		}

		if wayu.dry_run {
			fmt.println()
			print_info("[DRY RUN] Would update %d plugin(s); nothing was changed", would_update)
			return
		}
	}

	fmt.println()

	// Save updated metadata
	if !wayu.dry_run {
		// Create backup before writing
		config_file := get_plugins_json_config_file()
		defer delete(config_file)

		if os.exists(config_file) {
			backup_path, backup_ok := create_backup(config_file)
			if backup_ok {
				defer delete(backup_path)
			} else {
				print_warning("Warning: Failed to create backup")
			}
		}

		// Write updated config
		if !write_plugin_config_json(&config) {
			print_error_simple("Failed to save plugin metadata")
			os.exit(EXIT_CONFIG)
		}
	} else {
		print_info("[DRY RUN] Would save updated metadata")
	}

	// Summary
	if updated_count == 0 {
		print_info("No plugins updated")
	} else if updated_count == 1 {
		print_success("1 plugin updated")
	} else {
		print_success("%d plugins updated", updated_count)
	}

	// Regenerate plugins loader file for current shell
	if !wayu.dry_run {
		if !generate_plugins_file(wayu.shell) {
			print_warning("Warning: Failed to regenerate plugins loader")
		}
	}

	fmt.println()
	print_info("Restart your shell or run 'source ~/.%src' to reload plugins", wayu.shell_ext)

	if failed_count > 0 {
		print_error_simple("%d plugin(s) failed to update", failed_count)
		os.exit(EXIT_IOERR)
	}
}

// Report whether a plugin is pinned to a tag/commit (or sits on a detached
// HEAD). Pinned plugins must not be pulled: pull fails on a detached HEAD
// and would silently move a checkout the user pinned on purpose.
plugin_pinned_ref :: proc(plugin: ^PluginMetadata) -> (pinned: bool, ref: string) {
	if len(plugin.git.pinned_ref) > 0 {
		return true, plugin.git.pinned_ref
	}
	if plugin.git.ref_type == .Tag {
		return true, len(plugin.git.tag) > 0 ? plugin.git.tag : "tag"
	}
	if plugin.git.ref_type == .Commit {
		return true, len(plugin.git.commit) > 0 ? plugin.git.commit : "commit"
	}
	if plugin.git.branch == "HEAD" {
		return true, "detached HEAD"
	}
	return false, ""
}

// Refresh the fields a pull changes (branch, commit, timestamps) while
// preserving user-set pinning fields (ref_type, tag, pinned_ref).
plugin_refresh_git_metadata :: proc(plugin: ^PluginMetadata) {
	fresh := get_git_info(plugin.installed_path)

	delete(plugin.git.branch)
	delete(plugin.git.commit)
	delete(plugin.git.last_checked)
	delete(plugin.git.remote_commit)

	plugin.git.branch        = fresh.branch
	plugin.git.commit        = fresh.commit
	plugin.git.last_checked  = fresh.last_checked
	plugin.git.remote_commit = fresh.remote_commit
	// fresh.tag / fresh.pinned_ref are never set by get_git_info.
}

// Shared implementation for enable/disable plugin commands
// Sets enabled state in plugins.json and regenerates shell loader
// Idempotent: Setting a plugin to its current state returns EXIT_SUCCESS
// Per-direction verb forms used by the user-facing messaging in
// handle_plugin_set_enabled. Groups the five conjugations of enable/disable
// into a single struct so the proc body doesn't fan out across ten if-else
// ternaries. See thoughts/code_review_2026-04-24.md N7.
PluginVerbForms :: struct {
	word:   string, // "enable" (imperative / flag name)
	Word:   string, // "Enable" (sentence-start)
	ing:    string, // "Enabling"
	past:   string, // "enabled"
	header: string, // "Enabling Plugin" (used as section header)
}

PLUGIN_VERBS := [2]PluginVerbForms{
	{"disable", "Disable", "Disabling", "disabled", "Disabling Plugin"},
	{"enable",  "Enable",  "Enabling",  "enabled",  "Enabling Plugin"},
}

handle_plugin_set_enabled :: proc(args: []string, enable: bool) {
	v := PLUGIN_VERBS[enable ? 1 : 0]
	action_word     := v.word
	action_word_cap := v.Word
	action_ing      := v.ing
	action_past     := v.past
	header_text     := v.header

	// 1. Validate arguments
	if len(args) == 0 {
		print_error("Missing required argument: plugin name")
		fmt.println()
		fmt.printfln("Usage: wayu plugin %s <name>", action_word)
		fmt.println()
		fmt.println("Example:")
		fmt.printfln("  wayu plugin %s zsh-autosuggestions", action_word)
		fmt.println()
		fmt.printfln("%sHint:%s For interactive selection, use: %swayu --tui%s",
			get_muted(), RESET, get_primary(), RESET)
		os.exit(EXIT_USAGE)
	}

	plugin_name := args[0]

	// Hold the config lock across read-modify-write of plugins.json so
	// concurrent wayu runs cannot drop each other's changes. Every path out
	// of this proc is os.exit, which drops the lock with the process.
	config_lock_acquire_or_exit()

	// 2. Read plugin configuration
	config, ok := read_plugin_config_json()
	if !ok {
		os.exit(EXIT_CONFIG)
	}

	// 3. Find plugin by exact name (miss: suggestions on stderr, exit 65)
	plugin_ptr := find_plugin_or_exit(&config, plugin_name)

	// Messages use the canonical name (the arg may have matched display_name).
	// Cloned because config is freed before the final messages (proc always exits).
	plugin_name = strings.clone(plugin_ptr.name)

	// 4. Check if already in target state (idempotent operation)
	if plugin_ptr.enabled == enable {
		cleanup_plugin_config_json(&config)
		print_info("Plugin '%s' is already %s", plugin_name, action_past)
		os.exit(EXIT_SUCCESS)  // NOT an error - idempotent
	}

	// Display header
	print_header(header_text, EMOJI_COMMAND)
	fmt.println()

	// 5. Create backup before modifying (never in dry-run: no side effects)
	config_file := get_plugins_json_config_file()

	if !wayu.dry_run && os.exists(config_file) {
		backup_path, backup_ok := create_backup(config_file)
		if backup_ok {
			delete(backup_path)
		} else {
			print_warning("Warning: Failed to create backup")
		}
	}

	// 6. Set plugin enabled state
	plugin_ptr.enabled = enable

	// 7. Write updated configuration
	if !wayu.dry_run {
		if !write_plugin_config_json(&config) {
			delete(config_file)
			cleanup_plugin_config_json(&config)
			print_error_simple("Failed to save plugin configuration")
			os.exit(EXIT_CONFIG)
		}
	} else {
		print_info("[DRY RUN] Would save updated configuration")
	}

	// 8. Regenerate shell loader
	if !wayu.dry_run {
		if !generate_plugins_file(wayu.shell) {
			delete(config_file)
			cleanup_plugin_config_json(&config)
			print_error_simple("Failed to regenerate plugins loader")
			os.exit(EXIT_IOERR)
		}
	} else {
		print_info("[DRY RUN] Would regenerate shell loader")
	}

	// 9. Success
	delete(config_file)
	cleanup_plugin_config_json(&config)
	print_success("Plugin '%s' %s successfully", plugin_name, action_past)
	fmt.println()

	if enable {
		fmt.printfln("%sThe plugin will be loaded in new shell sessions.%s", BRIGHT_CYAN, RESET)
	} else {
		fmt.printfln("%sThe plugin will not be loaded in new shell sessions.%s", BRIGHT_CYAN, RESET)
	}
	fmt.printfln("Restart your shell or run 'source ~/.%src' to apply changes.", wayu.shell_ext)

	if !enable {
		fmt.println()
		fmt.printfln("%sTo re-enable:%s wayu plugin enable %s", get_muted(), RESET, plugin_name)
	}

	os.exit(EXIT_SUCCESS)
}

// Handle plugin enable command - enable a disabled plugin
// Sets enabled: true in plugins.json and regenerates shell loader
// CLI-only command (no interactive mode)
// Idempotent: Enabling an already-enabled plugin returns EXIT_SUCCESS
handle_plugin_enable :: proc(args: []string) {
	handle_plugin_set_enabled(args, true)
}

// Handle plugin disable command - disable an enabled plugin
// Sets enabled: false in plugins.json and regenerates shell loader
// CLI-only command (no interactive mode)
// Plugin remains installed, only prevents loading on shell startup
// Idempotent: Disabling an already-disabled plugin returns EXIT_SUCCESS
handle_plugin_disable :: proc(args: []string) {
	handle_plugin_set_enabled(args, false)
}

// Handle plugin priority command - set plugin load priority
// Lower priority numbers load first (default: 100)
// CLI-only command (no interactive mode)
handle_plugin_priority :: proc(args: []string) {
	// 1. Validate arguments
	if len(args) < 2 {
		print_error("Missing required arguments: plugin name and priority")
		fmt.println()
		fmt.println("Usage: wayu plugin priority <name> <number>")
		fmt.println()
		fmt.println("  Lower numbers load first (default: 100)")
		fmt.println()
		fmt.println("Example:")
		fmt.println("  wayu plugin priority zsh-autosuggestions 50")
		os.exit(EXIT_USAGE)
	}

	plugin_name := args[0]
	priority_str := args[1]

	// 2. Parse priority number
	priority, ok := strconv.parse_int(priority_str)
	if !ok {
		print_error_simple("Invalid priority number '%s'", priority_str)
		fmt.println()
		fmt.println("Priority must be a valid integer")
		os.exit(EXIT_USAGE)
	}

	// Hold the config lock across read-modify-write of plugins.json so
	// concurrent wayu runs cannot drop each other's changes.
	config_lock_acquire_or_exit()
	defer config_lock_release()

	// 3. Read config
	config, read_ok := read_plugin_config_json()
	if !read_ok {
		os.exit(EXIT_CONFIG)
	}
	defer cleanup_plugin_config_json(&config)

	// 4. Find plugin by exact name (miss: suggestions on stderr, exit 65).
	// Messages use the canonical name (the arg may have matched display_name).
	plugin := find_plugin_or_exit(&config, plugin_name)
	plugin_name = plugin.name

	if wayu.dry_run {
		print_info("[DRY RUN] Would set priority of '%s' to %d (current: %d)",
			plugin_name, priority, plugin.priority)
		return
	}

	// Display header
	print_header("Setting Plugin Priority", EMOJI_COMMAND)
	fmt.println()

	old_priority := plugin.priority
	plugin.priority = priority

	// 5. Create backup before modifying
	config_file := get_plugins_json_config_file()
	defer delete(config_file)

	if os.exists(config_file) {
		backup_path, backup_ok := create_backup(config_file)
		if backup_ok {
			defer delete(backup_path)
		} else {
			print_warning("Warning: Failed to create backup")
		}
	}

	// 6. Save config
	if !write_plugin_config_json(&config) {
		print_error_simple("Failed to save configuration")
		os.exit(EXIT_CANTCREAT)
	}

	// 7. Regenerate loader (load order changed)
	if !generate_plugins_file(wayu.shell) {
		print_warning("Warning: Failed to regenerate plugin loader")
		// Don't exit - config was saved successfully
	}

	// 8. Success
	print_success("Updated priority for '%s': %d → %d", plugin_name, old_priority, priority)
	fmt.println()
	fmt.println("Restart your shell for changes to take effect")
}

// Command handlers

// Handle plugin add command
handle_plugin_add :: proc(args: []string) {
	if len(args) == 0 {
		print_error_simple("Plugin name or URL required")
		print_plugin_add_help()
		os.exit(EXIT_USAGE)
	}

	// "<name-or-url>@<sha>" pins the plugin to that commit.
	name_or_url, pin_commit := split_plugin_commit_pin(args[0])

	// --use GLOB / --use=GLOB (repeatable): the files to load, matched at
	// the repository root, instead of auto-detection.
	use_globs := make([dynamic]string, context.temp_allocator)
	for i := 1; i < len(args); i += 1 {
		arg := args[i]
		glob: string
		if strings.has_prefix(arg, "--use=") {
			glob = arg[len("--use="):]
		} else if arg == "--use" {
			if i + 1 >= len(args) {
				print_error_simple("--use requires a file name or glob (e.g. --use '*.zsh')")
				os.exit(EXIT_USAGE)
			}
			i += 1
			glob = args[i]
		} else {
			print_error_simple("Unexpected argument '%s'", arg)
			print_plugin_add_help()
			os.exit(EXIT_USAGE)
		}
		if !is_valid_use_glob(glob) {
			print_error_simple("Invalid --use value '%s': give a file name or glob at the repository root (no '/')", glob)
			os.exit(EXIT_USAGE)
		}
		append(&use_globs, glob)
	}
	from_url := is_valid_git_url(name_or_url)

	// Plugin code is sourced into every shell: never fetch it in plaintext.
	if is_insecure_git_url(name_or_url) {
		print_error_simple("Refusing insecure plugin URL '%s'", name_or_url)
		fmt.println("Plaintext http:// and git:// can be tampered with in transit; use https:// or ssh instead.")
		os.exit(EXIT_DATAERR)
	}

	// Resolve plugin (all fields of `info` are owned)
	info, resolved := resolve_plugin(name_or_url)
	if !resolved {
		if is_valid_git_url(name_or_url) {
			print_error_simple("Cannot derive a valid plugin name from URL '%s'", name_or_url)
		} else {
			print_error_simple("Unknown plugin '%s'", name_or_url)
			fmt.println("\nRun 'wayu plugin search' to see available plugins")
		}
		os.exit(EXIT_DATAERR)
	}
	defer plugin_info_destroy(&info)

	// Hold the config lock across read-modify-write of plugins.json so
	// concurrent wayu runs cannot drop each other's changes.
	config_lock_acquire_or_exit()
	defer config_lock_release()

	// Read current config
	config, ok := read_plugin_config_json()
	if !ok {
		print_error_simple("Failed to read plugin configuration")
		os.exit(EXIT_CONFIG)
	}
	defer cleanup_plugin_config_json(&config)

	// Check if already installed (exact match — fuzzy would treat e.g. "git"
	// as installed whenever "forgit" is)
	if _, found := find_plugin_json(&config, info.name); found {
		print_warning("Plugin '%s' is already installed", info.name)
		os.exit(EXIT_SUCCESS)
	}

	hook_pre_plugin_install(info.name)

	print_header("Installing Plugin", EMOJI_COMMAND)
	print_info("Name: %s", info.name)
	print_info("URL: %s", info.url)
	if !from_url {
		print_info("Shell: %s", shell_compat_to_string(info.shell))
	}
	if pin_commit != "" {
		print_info("Pinned commit: %s", pin_commit)
	}
	if len(use_globs) > 0 {
		print_info("Load: %s", strings.join(use_globs[:], " ", context.temp_allocator))
	}
	fmt.println()

	// Create plugins directory if it doesn't exist
	plugins_dir := get_plugins_dir()
	defer delete(plugins_dir)

	if !os.exists(plugins_dir) && !wayu.dry_run {
		err := os.make_directory(plugins_dir)
		if err != nil {
			print_error_simple("Failed to create plugins directory: %v", err)
			os.exit(EXIT_CANTCREAT)
		}
	}

	// Clone repository
	plugin_path := fmt.aprintf("%s/%s", plugins_dir, info.name)
	defer delete(plugin_path)

	// Never clean up a directory we did not create.
	existed_before := os.exists(plugin_path)

	spinner := new_spinner(.Dots)
	spinner_text(&spinner, "Cloning repository")
	spinner_start(&spinner)

	success: bool
	clone_err: string
	if pin_commit != "" {
		success, clone_err = git_clone_at_commit(info.url, plugin_path, pin_commit)
	} else {
		success, clone_err = git_clone(info.url, plugin_path)
	}
	defer delete(clone_err)

	spinner_stop(&spinner)
	delete(spinner.text)

	if !success {
		if !existed_before {
			remove_cloned_plugin_dir(plugin_path, plugins_dir)
		}
		print_error_simple("Failed to clone plugin repository")
		if len(clone_err) > 0 {
			fmt.eprintln(clone_err)
		}
		os.exit(EXIT_IOERR)
	}

	if !wayu.dry_run {
		print_success("Cloned plugin repository")

		// Refuse a plugin that would load nothing: the loader would only
		// emit a comment while the install claimed success.
		loadable := plugin_loadable_shells(info.name, plugin_path, use_globs[:])
		loads := false
		if from_url {
			// Custom URL: record the shells it actually has files for, so a
			// fish-only repo added from zsh (or vice versa) loads where it can.
			compat, any_shell := shell_compat_from_loadable(loadable)
			if any_shell {
				info.shell = compat
				loads = true
			}
			print_info("Shell: %s (detected)", shell_compat_to_string(info.shell))
		} else {
			loads = plugin_compat_loads_any(info.shell, loadable)
		}
		if !loads {
			if !existed_before {
				remove_cloned_plugin_dir(plugin_path, plugins_dir)
			}
			print_plugin_nothing_to_load(info, use_globs[:])
			os.exit(EXIT_DATAERR)
		}
	} else if from_url {
		print_info("Shell: detected after cloning")
	}

	// Add to config
	git_info := get_git_info(plugin_path)
	if pin_commit != "" {
		// Record the pin: check/update skip the plugin and `plugin check`
		// verifies the checkout is still on this exact commit.
		git_info.ref_type = .Commit
		full_sha := capture_command([]string{"git", "-C", plugin_path, "rev-parse", "HEAD"})
		if len(full_sha) > 0 {
			git_info.pinned_ref = full_sha
		} else {
			delete(full_sha)
			git_info.pinned_ref = strings.clone(pin_commit)
		}
	}

	new_plugin := PluginMetadata{
		name = strings.clone(info.name),
		display_name = strings.clone(info.name),
		url = strings.clone(info.url),
		source_type = .GitHub,  // Default source
		enabled = true,
		shell = info.shell,
		installed_path = strings.clone(plugin_path),
		entry_file = "",  // Will be detected by generate_plugins_file
		use = make([dynamic]string),  // Empty = auto-detect (filled below)
		template = .Source,  // Default loading template
		git = git_info,
		dependencies = make([dynamic]string),  // Phase 4: Initialize empty
		priority = 100,  // Phase 5: Default priority
		profiles = make([dynamic]string),  // Empty = all profiles
		conflicts = ConflictInfo{},  // Phase 6: No conflicts yet
	}

	for glob in use_globs {
		append(&new_plugin.use, strings.clone(glob))
	}

	append(&config.plugins, new_plugin)

	// Phase 4: Validate no circular dependencies before writing config
	if !validate_no_circular_dependencies(&config) {
		if !existed_before {
			remove_cloned_plugin_dir(plugin_path, plugins_dir)
		}
		os.exit(EXIT_DATAERR)
	}

	if wayu.dry_run {
		print_info("[DRY RUN] Would add '%s' to plugins.json and regenerate the plugin loader", info.name)
		return
	}

	// Create backup before writing
	config_file := get_plugins_json_config_file()
	defer delete(config_file)

	if os.exists(config_file) {
		backup_path, backup_ok := create_backup(config_file)
		if backup_ok {
			defer delete(backup_path)
		}
	}

	// Write config
	if !write_plugin_config_json(&config) {
		if !existed_before {
			remove_cloned_plugin_dir(plugin_path, plugins_dir)
		}
		print_error_simple("Failed to write plugin configuration")
		os.exit(EXIT_IOERR)
	}

	// Generate plugins file for current shell
	if !generate_plugins_file(wayu.shell) {
		// Roll back: drop the new entry, rewrite config, remove the clone.
		last := pop(&config.plugins)
		cleanup_plugin_metadata(&last)
		write_plugin_config_json(&config)
		if !existed_before {
			remove_cloned_plugin_dir(plugin_path, plugins_dir)
		}
		generate_plugins_file(wayu.shell)
		print_error_simple("Failed to generate plugins loader")
		os.exit(EXIT_IOERR)
	}

	print_success("Plugin '%s' installed successfully", info.name)
	fmt.println()
	print_info("Restart your shell or run 'source ~/.%src' to load the plugin", wayu.shell_ext)

	hook_post_plugin_install(info.name)
}

// Remove a plugin directory, but only if it lies strictly inside the plugins
// root. Guards against wiping the root itself (empty/"." names from legacy
// configs) or anything outside it (hand-edited installed_path).
// Returns false when removal was refused or failed.
remove_cloned_plugin_dir :: proc(plugin_path: string, plugins_dir: string) -> bool {
	if wayu.dry_run {
		return true
	}
	#partial switch remove_plugin_dir_safely(plugin_path, plugins_dir) {
	case .Removed, .Missing:
		return true
	}
	return false
}

// Emit the plugin list as structured JSON. Shape:
//   { "plugins": [ {"name": ..., "enabled": bool, "priority": N,
//                   "shell": "zsh|bash|both|fish|any", "url": ...,
//                   "commit": ..., "installed_path": ...}, ... ],
//     "count": N, "enabled": M }
print_plugins_json :: proc(config: ^PluginConfigJSON) {
	enabled_count := 0
	for plugin in config.plugins {
		if plugin.enabled { enabled_count += 1 }
	}

	fmt.println("{")
	fmt.println(`  "plugins": [`)

	for plugin, i in config.plugins {
		if i > 0 { fmt.println(",") }
		enabled_str := plugin.enabled ? "true" : "false"
		// `{` is a struct-verb opener in Odin's fmt — emit via %c.
		fmt.printf(
			"    %c\"name\": \"%s\", \"enabled\": %s, \"priority\": %d, \"shell\": \"%s\", \"url\": \"%s\", \"commit\": \"%s\", \"installed_path\": \"%s\"%c",
			'{',
			plugin.name,
			enabled_str,
			plugin.priority,
			shell_compat_to_string(plugin.shell),
			plugin.url,
			plugin.git.commit,
			plugin.installed_path,
			'}',
		)
	}

	fmt.println()
	fmt.println("  ],")
	fmt.printfln("  \"count\": %d,", len(config.plugins))
	fmt.printfln("  \"enabled\": %d", enabled_count)
	fmt.println("}")
}

// Handle plugin list command
handle_plugin_list :: proc(args: []string) {
	// Run migration if needed
	if !migrate_plugin_config() {
		os.exit(EXIT_CONFIG)
	}

	// Use JSON5 config if it exists, otherwise fall back to old format
	json_file := get_plugins_json_config_file()
	defer delete(json_file)

	use_json := os.exists(json_file)

	if use_json {
		// Read from JSON5 config
		config, ok := read_plugin_config_json()
		if !ok {
			os.exit(EXIT_CONFIG)
		}
		defer cleanup_plugin_config_json(&config)

		if wayu.json_output {
			print_plugins_json(&config)
			return
		}

		if len(config.plugins) == 0 {
			print_info("No plugins installed")
			fmt.println("\nRun 'wayu plugin add <name>' to install a plugin")
			return
		}

		print_header("Installed Plugins", EMOJI_COMMAND)
		fmt.println()

		// Create table
		table := new_table([]string{"Name", "Status", "Priority", "Shell", "URL"})
		defer delete(table.rows)

		for plugin in config.plugins {
			status := plugin.enabled ? "✓ Active" : "○ Disabled"
			priority_str := fmt.aprintf("%d", plugin.priority)
			shell_str := shell_compat_to_string(plugin.shell)

			// Truncate URL for display
			url_display := plugin.url
			if len(url_display) > 40 {
				url_display = fmt.aprintf("%s...", plugin.url[:37])
			}

			row := []string{plugin.name, status, priority_str, shell_str, url_display}
			table_add_row(&table, row)
			delete(priority_str)

			if len(url_display) > 40 {
				delete(url_display)
			}
		}

		output := table_render(table, get_cli_terminal_width())
		defer delete(output)
		fmt.print(output)

		fmt.println()
		enabled_count := 0
		for plugin in config.plugins {
			if plugin.enabled {
				enabled_count += 1
			}
		}

		print_info("%d plugins installed (%d enabled)", len(config.plugins), enabled_count)
	} else {
		// Fall back to old format (for backward compatibility during transition)
		config := read_plugin_config()
		defer {
			for plugin in config.plugins {
				delete(plugin.name)
				delete(plugin.url)
				delete(plugin.installed_path)
				delete(plugin.entry_file)
			}
			delete(config.plugins)
		}

		if len(config.plugins) == 0 {
			print_info("No plugins installed")
			fmt.println("\nRun 'wayu plugin add <name>' to install a plugin")
			return
		}

		print_header("Installed Plugins", EMOJI_COMMAND)
		fmt.println()

		// Create table (old format fallback - priority defaults to 100)
		table := new_table([]string{"Name", "Status", "Priority", "Shell", "URL"})
		defer delete(table.rows)

		for plugin in config.plugins {
			status := plugin.enabled ? "✓ Active" : "○ Disabled"
			priority_str := fmt.aprintf("%d", 100)  // Old format doesn't have priority field
			shell_str := shell_compat_to_string(plugin.shell)

			// Truncate URL for display
			url_display := plugin.url
			if len(url_display) > 40 {
				url_display = fmt.aprintf("%s...", plugin.url[:37])
			}

			row := []string{plugin.name, status, priority_str, shell_str, url_display}
			table_add_row(&table, row)
			delete(priority_str)

			if len(url_display) > 40 {
				delete(url_display)
			}
		}

		output := table_render(table, get_cli_terminal_width())
		defer delete(output)
		fmt.print(output)

		fmt.println()
		enabled_count := 0
		for plugin in config.plugins {
			if plugin.enabled {
				enabled_count += 1
			}
		}

		print_info("%d plugins installed (%d enabled)", len(config.plugins), enabled_count)
	}
}

// Handle plugin remove command
handle_plugin_remove :: proc(args: []string) {
	// Hold the config lock across read-modify-write of plugins.json so
	// concurrent wayu runs cannot drop each other's changes.
	config_lock_acquire_or_exit()
	defer config_lock_release()

	// Read plugin configuration
	config, ok := read_plugin_config_json()
	if !ok {
		print_error_simple("Failed to read plugin configuration")
		os.exit(EXIT_CONFIG)
	}
	defer cleanup_plugin_config_json(&config)

	// A named rm on an empty list falls through to the miss report (exit 65).
	if len(config.plugins) == 0 && len(args) == 0 {
		print_info("No plugins installed")
		return
	}

	// Require explicit plugin name (no interactive selection in CLI)
	if len(args) == 0 {
		print_error("Missing required argument: plugin name")
		fmt.println()
		fmt.println("Usage: wayu plugin rm <name>")
		fmt.println()
		fmt.println("Example:")
		fmt.println("  wayu plugin rm syntax-highlighting")
		fmt.println()
		fmt.printfln("%sHint:%s For interactive selection, use: %swayu --tui%s",
			get_muted(), RESET, get_primary(), RESET)
		os.exit(EXIT_USAGE)
	}

	arg_name := args[0]

	// Exact match only: removal is destructive, so a fuzzy guess must never
	// pick the target (miss: suggestions on stderr, exit 65).
	plugin_ptr := find_plugin_or_exit(&config, arg_name)

	// From here on use the canonical name (arg may have matched display_name).
	// Cloned: the config entry is freed before the final message.
	plugin_name := strings.clone(plugin_ptr.name)
	defer delete(plugin_name)

	// Phase 1: Check for --yes flag (required for all removals)
	if !wayu.yes_flag {
		print_error("This operation requires confirmation.")
		fmt.println()
		print_info("Plugin to remove: %s", plugin_name)
		fmt.printfln("  Path: %s", plugin_ptr.installed_path)
		fmt.println()

		// Phase 2: Check if other plugins depend on this one
		dependents := check_plugin_dependents(plugin_name, &config)

		if len(dependents) > 0 {
			print_warning("Warning: The following plugins depend on '%s':", plugin_name)
			for dep in dependents {
				fmt.printfln("  - %s", dep)
			}
			fmt.println()
			print_warning("Removing this plugin may break these plugins.")
			fmt.println()
		}

		for dep in dependents {
			delete(dep)
		}
		delete(dependents)
		fmt.printfln("Add --yes flag to proceed:")
		fmt.printfln("  wayu plugin rm %s --yes", plugin_name)
		os.exit(EXIT_USAGE)
	}

	// Phase 3: Check for dependents (warning only since --yes was provided)
	dependents := check_plugin_dependents(plugin_name, &config)
	defer {
		for dep in dependents {
			delete(dep)
		}
		delete(dependents)
	}

	if len(dependents) > 0 {
		print_warning("Warning: The following plugins depend on '%s':", plugin_name)
		for dep in dependents {
			fmt.printfln("  - %s", dep)
		}
		fmt.println()
		print_warning("Removing this plugin may break these plugins.")
		fmt.println()
	}

	print_header("Removing Plugin", EMOJI_COMMAND)
	print_info("Name: %s", plugin_name)
	fmt.println()

	// Remove plugin directory — only when it is strictly inside the plugins
	// root (never the root itself, never outside it).
	plugins_dir := get_plugins_dir()
	defer delete(plugins_dir)

	installed_path := plugin_ptr.installed_path
	if len(installed_path) == 0 {
		// Nothing on disk to remove.
	} else if !is_path_inside_dir(installed_path, plugins_dir) {
		print_warning("Not deleting '%s': outside the plugins directory", installed_path)
	} else if wayu.dry_run {
		if is_symlink(installed_path) {
			print_info("[DRY RUN] Would remove symlink (target kept): %s", installed_path)
		} else {
			print_info("[DRY RUN] Would remove directory: %s", installed_path)
		}
	} else {
		was_symlink := is_symlink(installed_path)
		switch remove_plugin_dir_safely(installed_path, plugins_dir) {
		case .Removed:
			if was_symlink {
				print_success("Removed plugin symlink (its target was left untouched)")
			} else {
				print_success("Removed plugin directory")
			}
		case .Missing:
			// Nothing on disk; just drop the config entry.
		case .Outside:
			print_warning("Not deleting '%s': it resolves outside the plugins directory", installed_path)
		case .Failed:
			print_error_simple("Failed to remove plugin directory")
			os.exit(EXIT_IOERR)
		}
	}

	if wayu.dry_run {
		print_info("[DRY RUN] Would remove '%s' from plugins.json and regenerate the plugin loader", plugin_name)
		return
	}

	// Remove from config in place. config.plugins keeps ownership of the
	// remaining entries; the removed entry is freed here exactly once.
	for i := 0; i < len(config.plugins); i += 1 {
		if config.plugins[i].name == plugin_name {
			cleanup_plugin_metadata(&config.plugins[i])
			ordered_remove(&config.plugins, i)
			break
		}
	}

	// Create backup before writing
	config_file := get_plugins_json_config_file()
	defer delete(config_file)

	if os.exists(config_file) {
		backup_path, backup_ok := create_backup(config_file)
		if backup_ok {
			defer delete(backup_path)
		}
	}

	// Write config
	if !write_plugin_config_json(&config) {
		print_error_simple("Failed to write plugin configuration")
		os.exit(EXIT_IOERR)
	}

	// Generate plugins file
	if !generate_plugins_file(wayu.shell) {
		print_error_simple("Failed to generate plugins loader")
		os.exit(EXIT_IOERR)
	}

	print_success("Plugin '%s' removed successfully", plugin_name)
}

// Handle plugin get command - display plugin info and copy URL to clipboard
handle_plugin_get :: proc(args: []string) {
	if len(args) == 0 {
		print_error_simple("Plugin name required")
		fmt.println("\nUsage: wayu plugin get <name>")
		os.exit(EXIT_USAGE)
	}

	plugin_name := args[0]

	// Read current config (JSON format)
	config, ok := read_plugin_config_json()
	if !ok {
		print_error_simple("Failed to read plugin configuration")
		os.exit(EXIT_CONFIG)
	}
	defer cleanup_plugin_config_json(&config)

	// Find plugin by exact name (miss: suggestions on stderr, exit 65)
	plugin_ptr := find_plugin_or_exit(&config, plugin_name)

	// Display plugin information
	print_header("Plugin Information", EMOJI_COMMAND)
	fmt.println()

	// Create table with plugin details
	table := new_table([]string{"Property", "Value"})
	defer delete(table.rows)

	table_add_row(&table, []string{"Name", plugin_ptr.name})
	table_add_row(&table, []string{"URL", plugin_ptr.url})
	table_add_row(&table, []string{"Status", plugin_ptr.enabled ? "✓ Enabled" : "○ Disabled"})
	table_add_row(&table, []string{"Shell", shell_compat_to_string(plugin_ptr.shell)})
	table_add_row(&table, []string{"Path", plugin_ptr.installed_path})

	output := table_render(table, get_cli_terminal_width())
	defer delete(output)
	fmt.print(output)

	fmt.println()

	// Copy URL to clipboard — write URL to stdin of clipboard command (no shell)
	if !wayu.dry_run {
		clipboard_ok := false
		when ODIN_OS == .Darwin {
			// macOS: pbcopy reads from stdin
			clipboard_ok = run_command_with_stdin([]string{"pbcopy"}, plugin_ptr.url)
		} else when ODIN_OS == .Linux {
			// Linux: try xclip first, fall back to xsel
			clipboard_ok = run_command_with_stdin(
				[]string{"xclip", "-selection", "clipboard"}, plugin_ptr.url)
			if !clipboard_ok {
				clipboard_ok = run_command_with_stdin(
					[]string{"xsel", "--clipboard", "--input"}, plugin_ptr.url)
			}
		} else when ODIN_OS == .Windows {
			// Windows: clip reads from stdin
			clipboard_ok = run_command_with_stdin([]string{"clip"}, plugin_ptr.url)
		}

		if clipboard_ok {
			print_success("URL copied to clipboard: %s", plugin_ptr.url)
		} else {
			print_warning("Failed to copy URL to clipboard")
			print_info("URL: %s", plugin_ptr.url)
		}
	} else {
		print_info("[DRY RUN] Would copy URL to clipboard: %s", plugin_ptr.url)
	}
}

// Search the built-in popular plugins registry.
//
// Usage:
//   wayu plugin search                       – list all 55 entries
//   wayu plugin search <query>               – filter by name/key/description/category
//   wayu plugin search --category <cat>      – show only a specific category
//
// Recognized categories: syntax, completion, navigation, git, history,
//   prompt, productivity, tools, utility
handle_plugin_search :: proc(args: []string) {
	// Parse --category flag and free-text query from args.
	// Supported forms:
	//   search git
	//   search --category git
	//   search --category=git
	query:    string
	category: string

	i := 0
	for i < len(args) {
		arg := args[i]
		if strings.has_prefix(arg, "--category=") {
			category = strings.to_lower(arg[len("--category="):])
			i += 1
		} else if arg == "--category" || arg == "-c" {
			if i + 1 < len(args) {
				category = strings.to_lower(args[i + 1])
				i += 2
			} else {
				print_error_simple("--category requires a value")
				os.exit(EXIT_USAGE)
			}
		} else {
			query = strings.to_lower(arg)
			i += 1
		}
	}
	defer if len(query)    > 0 { delete(query) }
	defer if len(category) > 0 { delete(category) }

	print_header("Popular Plugins", EMOJI_COMMAND)
	fmt.println()

	table := new_table([]string{"Key", "Category", "Shell", "Description"})
	defer delete(table.rows)

	matched := 0
	for entry in POPULAR_PLUGINS {
		info := entry.info

		// Category filter (exact match on category field).
		if len(category) > 0 && entry.category != category {
			continue
		}

		// Free-text filter: key, name, description, or category substring.
		if len(query) > 0 {
			key_lower  := strings.to_lower(entry.key)
			name_lower := strings.to_lower(info.name)
			desc_lower := strings.to_lower(info.description)
			cat_lower  := strings.to_lower(entry.category)
			defer delete(key_lower)
			defer delete(name_lower)
			defer delete(desc_lower)
			defer delete(cat_lower)

			if !strings.contains(key_lower,  query) &&
			   !strings.contains(name_lower, query) &&
			   !strings.contains(desc_lower, query) &&
			   !strings.contains(cat_lower,  query) {
				continue
			}
		}

		shell_str := shell_compat_to_string(info.shell)
		table_add_row(&table, []string{entry.key, entry.category, shell_str, info.description})
		matched += 1
	}

	if matched == 0 {
		if len(category) > 0 {
			fmt.printfln("No plugins found in category %q", category)
			fmt.println()
			fmt.println("Categories: syntax, completion, navigation, git, history, prompt, productivity, tools, utility")
		} else {
			fmt.printfln("No plugins found matching %q", query)
			fmt.println()
			fmt.println("Run 'wayu plugin search' to list all popular plugins.")
		}
		return
	}

	output := table_render(table, get_cli_terminal_width())
	defer delete(output)
	fmt.print(output)

	fmt.println()
	fmt.printfln("%sTo install:%s wayu plugin add <key>", get_muted(), RESET)
	fmt.printfln("%sFilter by category:%s wayu plugin search --category <cat>", get_muted(), RESET)
}


