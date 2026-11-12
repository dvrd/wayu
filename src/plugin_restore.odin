package wayu

import "core:fmt"
import "core:os"

handle_plugin_restore :: proc(args: []string) {
	if len(args) != 0 {
		print_error_simple("Usage: wayu plugin restore [--dry-run]")
		wayu_exit(EXIT_USAGE)
	}
	// Return before exiting so rollback and lock-release defers always run.
	code, err := plugin_restore()
	if err != "" {
		print_error_simple("%s", err)
		wayu_exit(code)
	}
}

// Reconstruct only missing checkouts. On failure before the metadata is
// saved, remove only directories this invocation created; existing working
// trees and the imported plugins.json remain untouched.
plugin_restore :: proc() -> (int, string) {
	config_lock_acquire_or_exit()
	defer config_lock_release()
	config, ok := read_plugin_config_json(relocate = true)
	defer cleanup_plugin_config_json(&config)
	if !ok do return EXIT_CONFIG, "Cannot restore invalid plugins.json"
	if config.version != "1.0" {
		return EXIT_CONFIG, "Unsupported plugins.json version; upgrade wayu before restoring"
	}
	if len(config.plugins) == 0 {
		print_info("No plugins to restore")
		return EXIT_SUCCESS, ""
	}

	// Validate the whole plan before contacting any remote or creating dirs.
	for &p in config.plugins {
		if p.url == "" do return EXIT_CONFIG, fmt.tprintf("Plugin '%s' has no URL", p.name)
		_, problem := plugin_restore_revision(&p)
		if problem != "" do return EXIT_CONFIG, fmt.tprintf("Plugin '%s': %s", p.name, problem)
		if is_symlink(p.installed_path) {
			return EXIT_CONFIG, fmt.tprintf(
				"Plugin '%s': restore refuses a symlinked checkout",
				p.name,
			)
		}
		if os.exists(p.installed_path) {
			if !os.exists(fmt.tprintf("%s/.git", p.installed_path)) {
				return EXIT_CONFIG, fmt.tprintf(
					"Plugin '%s': destination exists but is not a checkout",
					p.name,
				)
			}
			origin := capture_command(
				git_argv("-C", p.installed_path, "config", "--get", "remote.origin.url"),
			)
			matches := origin == p.url
			delete(origin)
			if !matches {
				return EXIT_CONFIG, fmt.tprintf(
					"Plugin '%s': existing checkout has a different origin",
					p.name,
				)
			}
		}
	}

	if wayu.dry_run {
		for &p in config.plugins {
			if os.exists(p.installed_path) {
				print_info("[DRY RUN] Keep existing checkout: %s", p.name)
			} else {
				revision, _ := plugin_restore_revision(&p)
				print_info(
					"[DRY RUN] Restore %s at %s into %s",
					p.name,
					revision == "" ? "remote HEAD" : revision,
					p.installed_path,
				)
			}
		}
		print_info(
			"[DRY RUN] Would back up plugins.json, save local paths and regenerate shell files",
		)
		return EXIT_SUCCESS, ""
	}

	plugins_dir := get_plugins_dir()
	defer delete(plugins_dir)
	if err := make_wayu_dir(plugins_dir); err != nil {
		return EXIT_CANTCREAT, fmt.tprintf("Cannot create plugins directory: %v", err)
	}
	created := make([dynamic]string)
	saved := false
	defer {
		if !saved {
			for path in created {
				remove_cloned_plugin_dir(path, plugins_dir)
			}
		}
		delete(created)
	}
	for &p in config.plugins {
		if os.exists(p.installed_path) {
			print_info("Keeping existing checkout: %s", p.name)
			continue
		}
		append(&created, p.installed_path)
		cloned, err := plugin_clone_for_restore(&p)
		if !cloned {
			message := fmt.tprintf("Cannot restore '%s': %s", p.name, err)
			delete(err)
			return EXIT_IOERR, message
		}
		delete(err)
		loadable := plugin_loadable_shells(p.name, p.installed_path, p.use[:])
		if !plugin_compat_loads_any(p.shell, loadable) {
			return EXIT_DATAERR, fmt.tprintf(
				"Plugin '%s' has no loadable files for its configured shells",
				p.name,
			)
		}
		// Preserve branch/tag/pin and every user setting. Store the full SHA
		// so the next reconstruction can select the same revision exactly.
		delete(p.git.commit)
		p.git.commit = capture_command(git_argv("-C", p.installed_path, "rev-parse", "HEAD"))
		print_success("Restored plugin '%s'", p.name)
	}
	if err := plugin_config_save(&config); err != "" do return EXIT_CANTCREAT, err
	saved = true
	verified, valid := read_plugin_config_json()
	cleanup_plugin_config_json(&verified)
	if !valid do return EXIT_CONFIG, "Cannot verify restored plugins.json; its backup was kept"
	for shell in ([]ShellType{.ZSH, .BASH, .FISH}) {
		if !generate_plugins_file(shell) {
			return EXIT_IOERR, "Plugins restored, but loader generation failed; run: wayu build"
		}
	}
	regenerate_init_core_silently()
	print_success("Plugin restore complete; open a new shell")
	return EXIT_SUCCESS, ""
}

// The recorded commit wins over a moving branch or tag. Old metadata with
// no commit can still select its tag/branch, or the remote's default HEAD.
plugin_restore_revision :: proc(p: ^PluginMetadata) -> (revision: string, problem: string) {
	commit := p.git.commit
	if p.git.ref_type == .Commit && p.git.pinned_ref != "" {
		commit = p.git.pinned_ref
	}
	if commit != "" {
		if !is_valid_commit_sha(commit) do return "", "recorded commit must be 7-40 hexadecimal digits"
		return commit, ""
	}
	if p.git.ref_type == .Commit do return "", "commit-pinned plugin has no recorded commit"
	if p.git.ref_type == .Tag {
		tag := p.git.pinned_ref != "" ? p.git.pinned_ref : p.git.tag
		if tag == "" do return "", "tag-pinned plugin has no tag"
		return fmt.tprintf("refs/tags/%s", tag), ""
	}
	if p.git.pinned_ref != "" do return "", "pinned_ref requires a tag or commit ref_type"
	if p.git.branch != "" && p.git.branch != "HEAD" {
		return fmt.tprintf("refs/remotes/origin/%s", p.git.branch), ""
	}
	return "", ""
}
