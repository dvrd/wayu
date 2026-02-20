#+feature dynamic-literals
package wayu

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:c/libc"

// Shell compatibility for plugins
ShellCompat :: enum {
	ZSH,
	BASH,
	BOTH,
}

// Plugin information from registry
PluginInfo :: struct {
	name:        string,
	url:         string,
	shell:       ShellCompat,
	description: string,
}

// Installed plugin with metadata
InstalledPlugin :: struct {
	name:           string,
	url:            string,
	enabled:        bool,
	shell:          ShellCompat,
	installed_path: string,
	entry_file:     string, // Main file to source
}

// Plugin configuration state
PluginConfig :: struct {
	plugins: [dynamic]InstalledPlugin,
}

// Enhanced plugin metadata with git tracking, dependencies, and conflicts (JSON5 format)
PluginMetadata :: struct {
	name:           string,
	url:            string,
	enabled:        bool,
	shell:          ShellCompat,
	installed_path: string,
	entry_file:     string,
	git:            GitMetadata,
	dependencies:   [dynamic]string,
	priority:       int,
	config:         map[string]string,
	conflicts:      ConflictInfo,
}

// Git metadata for update tracking
GitMetadata :: struct {
	branch:        string,  // Current branch (default: "master" or "main")
	commit:        string,  // Local commit SHA (short form)
	last_checked:  string,  // ISO 8601 timestamp of last update check
	remote_commit: string,  // Remote commit SHA (short form)
}

// Conflict detection information
ConflictInfo :: struct {
	env_vars:            [dynamic]string,  // Environment variables this plugin sets
	functions:           [dynamic]string,  // Functions this plugin defines
	aliases_:            [dynamic]string,  // Aliases this plugin creates
	detected:            bool,             // Whether conflicts were detected
	conflicting_plugins: [dynamic]string,  // Names of plugins with conflicts
}

// Enhanced plugin configuration (JSON5 format)
PluginConfigJSON :: struct {
	version:      string,
	last_updated: string,  // ISO 8601 timestamp
	plugins:      [dynamic]PluginMetadata,
}

// Popular plugins registry - hardcoded for simplicity and speed
POPULAR_PLUGINS := map[string]PluginInfo{
	"syntax-highlighting" = {
		name = "zsh-syntax-highlighting",
		url = "https://github.com/zsh-users/zsh-syntax-highlighting.git",
		shell = .ZSH,
		description = "Fish-like syntax highlighting for ZSH",
	},
	"autosuggestions" = {
		name = "zsh-autosuggestions",
		url = "https://github.com/zsh-users/zsh-autosuggestions.git",
		shell = .ZSH,
		description = "Fish-like autosuggestions for ZSH",
	},
	"fast-syntax-highlighting" = {
		name = "fast-syntax-highlighting",
		url = "https://github.com/zdharma-continuum/fast-syntax-highlighting.git",
		shell = .ZSH,
		description = "Feature-rich syntax highlighting for ZSH",
	},
	"completions" = {
		name = "zsh-completions",
		url = "https://github.com/zsh-users/zsh-completions.git",
		shell = .ZSH,
		description = "Additional completion definitions for ZSH",
	},
	"history-substring-search" = {
		name = "zsh-history-substring-search",
		url = "https://github.com/zsh-users/zsh-history-substring-search.git",
		shell = .ZSH,
		description = "Fish-like history search",
	},
	"git-open" = {
		name = "git-open",
		url = "https://github.com/paulirish/git-open.git",
		shell = .BOTH,
		description = "Open repo in browser from command line",
	},
	"z" = {
		name = "z",
		url = "https://github.com/rupa/z.git",
		shell = .BOTH,
		description = "Jump to frecent directories",
	},
	"you-should-use" = {
		name = "zsh-you-should-use",
		url = "https://github.com/MichaelAquilina/zsh-you-should-use.git",
		shell = .ZSH,
		description = "Reminds you to use aliases",
	},
	"colored-man-pages" = {
		name = "zsh-colored-man-pages",
		url = "https://github.com/ael-code/zsh-colored-man-pages.git",
		shell = .ZSH,
		description = "Colorize man pages",
	},
}

// Parse shell compatibility from string
parse_shell_compat :: proc(shell_str: string) -> ShellCompat {
	shell_lower := strings.to_lower(shell_str)
	defer delete(shell_lower)

	switch shell_lower {
	case "zsh":
		return .ZSH
	case "bash":
		return .BASH
	case "both":
		return .BOTH
	}
	return .BOTH
}

// Convert shell compatibility to string
shell_compat_to_string :: proc(compat: ShellCompat) -> string {
	switch compat {
	case .ZSH:
		return "zsh"
	case .BASH:
		return "bash"
	case .BOTH:
		return "both"
	}
	return "both"
}

// Helper: Get current timestamp in ISO 8601 format
get_iso8601_timestamp :: proc() -> string {
	now := time.now()
	year, month, day := time.date(now)
	hour, minute, second := time.clock(now)
	return fmt.aprintf("%d-%02d-%02dT%02d:%02d:%02dZ",
		year, month, day, hour, minute, second)
}

// Execute command and return trimmed output
exec_command_output :: proc(cmd: string) -> string {
	// Use unique temporary file for output to avoid race conditions
	now := time.now()
	unix_nanos := time.to_unix_nanoseconds(now)
	temp_file := fmt.aprintf("/tmp/wayu_cmd_output_%d.txt", unix_nanos)
	defer delete(temp_file)

	full_cmd := fmt.aprintf("%s > %s 2>&1", cmd, temp_file)
	defer delete(full_cmd)

	cmd_cstr := strings.clone_to_cstring(full_cmd)
	defer delete(cmd_cstr)

	result := libc.system(cmd_cstr)
	if result != 0 {
		// Clean up temp file on error
		os.remove(temp_file)
		return ""
	}

	data, read_err := os.read_entire_file(temp_file, context.allocator)
	if read_err != nil {
		os.remove(temp_file)
		return ""
	}
	defer delete(data)

	// Clean up temp file after reading
	os.remove(temp_file)

	output := string(data)
	trimmed := strings.trim_space(output)
	// Clone the trimmed string before data is deleted
	return strings.clone(trimmed)
}

// Get git information for an installed plugin
get_git_info :: proc(plugin_dir: string) -> GitMetadata {
	info := GitMetadata{}

	if !os.exists(plugin_dir) {
		return info
	}

	// Validate plugin_dir against shell injection
	if !is_safe_shell_arg(plugin_dir) {
		print_error_simple("Error: Plugin directory path contains unsafe characters")
		return info
	}

	// Get current branch
	branch_cmd := fmt.aprintf("git -C \"%s\" rev-parse --abbrev-ref HEAD 2>/dev/null", plugin_dir)
	defer delete(branch_cmd)
	info.branch = exec_command_output(branch_cmd)

	// Get local commit (short SHA)
	commit_cmd := fmt.aprintf("git -C \"%s\" rev-parse --short HEAD 2>/dev/null", plugin_dir)
	defer delete(commit_cmd)
	info.commit = exec_command_output(commit_cmd)

	// Remote commit will be fetched during check/update
	info.remote_commit = info.commit
	info.last_checked = get_iso8601_timestamp()

	return info
}

// Cleanup helper for PluginMetadata
cleanup_plugin_metadata :: proc(plugin: ^PluginMetadata) {
	delete(plugin.name)
	delete(plugin.url)
	delete(plugin.installed_path)
	delete(plugin.entry_file)
	delete(plugin.git.branch)
	delete(plugin.git.commit)
	delete(plugin.git.last_checked)
	delete(plugin.git.remote_commit)
	delete(plugin.dependencies)
	delete(plugin.config)
	for ev in plugin.conflicts.env_vars {
		delete(ev)
	}
	delete(plugin.conflicts.env_vars)
	for fn in plugin.conflicts.functions {
		delete(fn)
	}
	delete(plugin.conflicts.functions)
	for al in plugin.conflicts.aliases_ {
		delete(al)
	}
	delete(plugin.conflicts.aliases_)
	for cp in plugin.conflicts.conflicting_plugins {
		delete(cp)
	}
	delete(plugin.conflicts.conflicting_plugins)
}

// Cleanup helper for PluginConfigJSON
cleanup_plugin_config_json :: proc(config: ^PluginConfigJSON) {
	delete(config.version)
	delete(config.last_updated)
	for &plugin in config.plugins {
		cleanup_plugin_metadata(&plugin)
	}
	delete(config.plugins)
}


// Handle plugin command routing
handle_plugin_command :: proc(action: Action, args: []string) {
	#partial switch action {
	case .ADD:
		handle_plugin_add(args)
	case .REMOVE:
		handle_plugin_remove(args)
	case .LIST:
		handle_plugin_list(args)
	case .GET:
		handle_plugin_get(args)
	case .CHECK:
		handle_plugin_check(args)
	case .UPDATE:
		handle_plugin_update(args)
	case .ENABLE:
		handle_plugin_enable(args)
	case .DISABLE:
		handle_plugin_disable(args)
	case .PRIORITY:
		handle_plugin_priority(args)
	case .HELP:
		print_plugin_help()
	case:
		print_error_simple("Unknown plugin action")
		print_plugin_help()
		os.exit(1)
	}
}
