// env_snapshot.odin - Cross-reference TOML data with actual shell environment
//
// Provides snapshots of:
// - PATH (colon-separated)
// - environment variables (process env)
// - shell aliases (via `$SHELL -i -c alias`)
//
// Cached per-invocation to avoid re-spawning shells for multiple list commands.

package wayu

import "core:fmt"
import "core:os"
import "core:strings"
import "core:strconv"

EntrySource :: enum {
	WAYU_ACTIVE,    // in wayu.toml AND in current env
	WAYU_INACTIVE,  // in wayu.toml but NOT in current env
	EXTERNAL,       // in current env but NOT in wayu.toml
	SHADOWED,       // in both but values differ
}

// Cached snapshot (per-invocation)
@private
ENV_SNAPSHOT_CACHE: struct {
	initialized: bool,
	path_entries: [dynamic]string,
	env_vars: map[string]string,
	aliases: map[string]string,
} = {}

// snapshot_path_entries splits $PATH on `:` and returns a slice
// Caches result on first call.
snapshot_path_entries :: proc() -> [dynamic]string {
	if ENV_SNAPSHOT_CACHE.initialized && len(ENV_SNAPSHOT_CACHE.path_entries) > 0 {
		return ENV_SNAPSHOT_CACHE.path_entries
	}

	path_str := os.get_env("PATH", context.allocator)
	defer delete(path_str)

	entries := strings.split(path_str, ":", context.allocator)
	for entry in entries {
		append(&ENV_SNAPSHOT_CACHE.path_entries, entry)
	}

	ENV_SNAPSHOT_CACHE.initialized = true
	return ENV_SNAPSHOT_CACHE.path_entries
}

// snapshot_env_var returns the value of an environment variable, or nil if not set
// Caches all env vars on first call.
snapshot_env_var :: proc(name: string) -> Maybe(string) {
	if !ENV_SNAPSHOT_CACHE.initialized {
		// Populate cache from process environment via os.environ proc
		env_list, err := os.environ(context.allocator)
		if err == nil {
			defer delete(env_list)
			for pair in env_list {
				parts := strings.split(pair, "=", context.allocator)
				defer delete(parts)
				if len(parts) >= 2 {
					key := parts[0]
					value := strings.join(parts[1:], "=", context.allocator)
					defer delete(value)
					ENV_SNAPSHOT_CACHE.env_vars[key] = strings.clone(value)
				}
			}
		}
		ENV_SNAPSHOT_CACHE.initialized = true
	}

	if val, ok := ENV_SNAPSHOT_CACHE.env_vars[name]; ok {
		return val
	}
	return nil
}

// snapshot_aliases spawns $SHELL -i -c alias and parses output
// Caches result on first call (expensive, ~100-500ms for interactive shell)
// Falls back gracefully if shell spawn fails.
snapshot_aliases :: proc() -> map[string]string {
	if ENV_SNAPSHOT_CACHE.initialized && len(ENV_SNAPSHOT_CACHE.aliases) > 0 {
		return ENV_SNAPSHOT_CACHE.aliases
	}

	// Try to spawn shell and capture alias list
	shell := os.get_env("SHELL", context.allocator)
	defer delete(shell)
	if shell == "" {
		shell = "zsh"  // Default fallback
	}

	// Use a temporary file to capture alias output (more reliable than pipe)
	temp_file := "/tmp/wayu_aliases.tmp"
	cmd := fmt.aprintf("%s -i -c 'alias > %s' 2>/dev/null || true", shell, temp_file, allocator = context.allocator)
	defer delete(cmd)

	// Run in background to avoid blocking
	ret := run_shell_command(cmd)

	// Parse the temp file if it exists
	if os.exists(temp_file) {
		alias_data, err := os.read_entire_file(temp_file, context.allocator)
		if err == nil {
			defer delete(alias_data)
			alias_text := string(alias_data)
			lines := strings.split(alias_text, "\n", context.allocator)
			defer delete(lines)

			for line in lines {
				if line == "" {
					continue
				}
				// Parse lines like: alias foo='bar' or alias foo=bar
				if strings.has_prefix(line, "alias ") {
					rest := strings.trim_prefix(line, "alias ")
					// Find the first = to split name and value
					if eq_idx := strings.index(rest, "="); eq_idx != -1 {
						name := rest[:eq_idx]
						value := rest[eq_idx+1:]
						// Strip surrounding quotes if present
						value = strings.trim(value, "'\"")
						ENV_SNAPSHOT_CACHE.aliases[name] = strings.clone(value)
					}
				}
			}
		}
		// Clean up temp file
		os.remove(temp_file)
	}

	ENV_SNAPSHOT_CACHE.initialized = true
	return ENV_SNAPSHOT_CACHE.aliases
}

// classify_entry determines the source of an entry
// wayu_value is the value declared in wayu.toml (or empty string if not present)
// env_value is the value from the shell environment (or nil if not present)
classify_entry :: proc(name: string, wayu_value: string, env_value: Maybe(string)) -> EntrySource {
	has_wayu := wayu_value != ""
	has_env := env_value != nil

	if has_wayu && has_env {
		// Both present — check if they match
		if env_value == wayu_value {
			return .WAYU_ACTIVE
		} else {
			return .SHADOWED
		}
	} else if has_wayu {
		return .WAYU_INACTIVE
	} else if has_env {
		return .EXTERNAL
	}

	// Neither — shouldn't happen in normal usage
	return .EXTERNAL
}

// cleanup_env_snapshot frees the cached snapshot (call at program end)
cleanup_env_snapshot :: proc() {
	delete(ENV_SNAPSHOT_CACHE.path_entries)
	for k, v in ENV_SNAPSHOT_CACHE.env_vars {
		delete(v)
	}
	delete(ENV_SNAPSHOT_CACHE.env_vars)
	for k, v in ENV_SNAPSHOT_CACHE.aliases {
		delete(v)
	}
	delete(ENV_SNAPSHOT_CACHE.aliases)
}

// run_shell_command executes a shell command via sh -c
// Returns true if command exits with 0, false otherwise.
// Minimally intrusive — stdout/stderr to /dev/null.
@private
run_shell_command :: proc(cmd: string) -> bool {
	// Use /bin/sh for portability
	args := []string{"sh", "-c", cmd}
	return run_command(args)
}
