// env_snapshot.odin - Cross-reference TOML data with actual shell environment
//
// Provides snapshots of:
// - PATH (colon-separated)
// - environment variables (process env)
// - shell aliases (via `$SHELL -i -c alias`)
//
// Cached per-invocation to avoid re-spawning shells for multiple list commands.

package wayu

import "base:runtime"
import "core:crypto"
import "core:os"
import "core:strings"
import "core:sys/posix"

EntrySource :: enum {
	WAYU_ACTIVE, // in wayu.toml AND in current env
	WAYU_INACTIVE, // in wayu.toml but NOT in current env
	EXTERNAL, // in current env but NOT in wayu.toml
	SHADOWED, // in both but values differ
}

// Cached snapshot (per-invocation). Each cache has its own init flag: a
// single shared flag made snapshot_env_var skip populating env_vars whenever
// PATH or aliases had been snapshotted first (constants then showed inactive).
@(private)
ENV_SNAPSHOT_CACHE: struct {
	path_initialized:    bool,
	aliases_initialized: bool,
	path_entries:        [dynamic]string,
	// Only the variables looked up (never a copy of the whole environment,
	// which holds exported secrets); a missing one is cached as absent.
	env_vars:            map[string]Maybe(string),
	aliases:             map[string]string,
} = {}

// snapshot_path_entries splits $PATH on `:`. The result is cached on the
// first call and OWNED BY THE CACHE (snapshot_allocator): callers must not
// delete the array or its strings (that would double free on the next call).
snapshot_path_entries :: proc() -> [dynamic]string {
	if ENV_SNAPSHOT_CACHE.path_initialized {
		return ENV_SNAPSHOT_CACHE.path_entries
	}
	context.allocator = snapshot_allocator()

	path_str := os.get_env("PATH", context.allocator)
	defer delete(path_str)

	entries := strings.split(path_str, ":", context.allocator)
	defer delete(entries)
	for entry in entries {
		append(&ENV_SNAPSHOT_CACHE.path_entries, strings.clone(entry))
	}

	ENV_SNAPSHOT_CACHE.path_initialized = true
	return ENV_SNAPSHOT_CACHE.path_entries
}

// snapshot_env_var returns the value of an environment variable, or nil if
// not set. Each name is read once and cached (owned by the cache); only the
// names asked for are copied, so the values of unrelated variables (e.g.
// exported secrets) are never duplicated on the heap.
snapshot_env_var :: proc(name: string) -> Maybe(string) {
	if val, ok := ENV_SNAPSHOT_CACHE.env_vars[name]; ok {
		return val
	}
	context.allocator = snapshot_allocator()
	val: Maybe(string)
	if v, found := os.lookup_env(name, context.allocator); found {
		val = v
	}
	ENV_SNAPSHOT_CACHE.env_vars[strings.clone(name)] = val
	return val
}

// Is `name` set in the environment? Copies nothing: for secrets, whose
// presence is all a list view shows.
snapshot_env_has :: proc(name: string) -> bool {
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	return posix.getenv(cname) != nil
}

// snapshot_aliases spawns `$SHELL -i -c alias` and parses its output.
// Caches result on first call (expensive, ~100-500ms for interactive shell)
// Falls back gracefully if shell spawn fails.
//
// Output is read through a pipe (capture_command) instead of a fixed
// /tmp file, which raced between concurrent invocations and could be
// redirected through a planted symlink.
snapshot_aliases :: proc() -> map[string]string {
	if ENV_SNAPSHOT_CACHE.aliases_initialized {
		return ENV_SNAPSHOT_CACHE.aliases
	}
	ENV_SNAPSHOT_CACHE.aliases_initialized = true
	context.allocator = snapshot_allocator()

	shell := os.get_env("SHELL", context.allocator)
	defer delete(shell)
	shell_bin := shell if len(shell) > 0 else "zsh"

	args := []string{shell_bin, "-i", "-c", "alias"}
	// An rc file that sleeps, prompts or attaches tmux must not freeze wayu
	// (TUI or CLI): give up after a deadline, listing no external aliases.
	output: string
	r := run_command_timeout(args, ALIAS_SNAPSHOT_TIMEOUT_MS)
	if r.ok {
		output = r.stdout
		r.stdout = ""
	}
	command_result_destroy(&r)
	defer if len(output) > 0 {
		delete(output)
	}

	parse_alias_listing(output, &ENV_SNAPSHOT_CACHE.aliases)
	return ENV_SNAPSHOT_CACHE.aliases
}

ALIAS_SNAPSHOT_TIMEOUT_MS :: 3_000

// Parse the output of the `alias` builtin into name -> command.
// Handles both formats:
//   zsh:  ll='ls -la'          (or ll=ls when no quoting is needed)
//   bash: alias ll='ls -la'
// Values are shell words; quoting ('...', "...", \x and the '\'' idiom) is
// removed. Inserted keys and values are heap-allocated.
parse_alias_listing :: proc(text: string, out: ^map[string]string) {
	it := text
	for line in strings.split_lines_iterator(&it) {
		l := strings.trim_right(line, "\r")
		has_alias_kw := strings.has_prefix(l, "alias ")
		l = strings.trim_prefix(l, "alias ")
		eq := strings.index_byte(l, '=')
		sp := strings.index_byte(l, ' ')
		// fish: `alias name 'value'` (space-separated, fish quoting).
		if has_alias_kw && sp > 0 && (eq < 0 || sp < eq) {
			name := l[:sp]
			value := fish_unquote_word(strings.trim_left_space(l[sp + 1:]))
			if old, exists := out[name]; exists {
				delete(old)
				out[name] = value
			} else {
				out[strings.clone(name)] = value
			}
			continue
		}
		if eq <= 0 {
			continue
		}
		name := l[:eq]
		// zsh quotes names containing special chars: 'a-b'=...
		if len(name) >= 2 && name[0] == '\'' && name[len(name) - 1] == '\'' {
			name = name[1:len(name) - 1]
		}
		if len(name) == 0 {
			continue
		}
		value := shell_unquote_word(l[eq + 1:])
		if old, exists := out[name]; exists {
			delete(old)
			out[name] = value
		} else {
			out[strings.clone(name)] = value
		}
	}
}

// Remove shell quoting from a single word as printed by `alias`.
// Returns a heap-allocated string.
shell_unquote_word :: proc(s: string) -> string {
	sb := strings.builder_make()
	i := 0
	for i < len(s) {
		c := s[i]
		switch c {
		case '\'':
			end := strings.index_byte(s[i + 1:], '\'')
			if end < 0 {
				strings.write_string(&sb, s[i + 1:])
				i = len(s)
			} else {
				strings.write_string(&sb, s[i + 1:i + 1 + end])
				i += end + 2
			}
		case '"':
			i += 1
			for i < len(s) && s[i] != '"' {
				if s[i] == '\\' && i + 1 < len(s) {
					i += 1
				}
				strings.write_byte(&sb, s[i])
				i += 1
			}
			i += 1
		case '\\':
			if i + 1 < len(s) {
				strings.write_byte(&sb, s[i + 1])
			}
			i += 2
		case '$':
			// bash may print $'...' ANSI-C strings; keep the inner text.
			if i + 1 < len(s) && s[i + 1] == '\'' {
				i += 1
				continue
			}
			strings.write_byte(&sb, c)
			i += 1
		case:
			strings.write_byte(&sb, c)
			i += 1
		}
	}
	return strings.to_string(sb)
}

// Remove fish quoting from one word as printed by fish's `alias`: inside
// '...' only `\'` and `\\` are escapes; inside "..." `\"`, `\$`, `\\`;
// outside quotes a backslash escapes the next byte. Heap-allocated.
fish_unquote_word :: proc(s: string) -> string {
	sb := strings.builder_make()
	quote: byte = 0
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if quote == 0 && (c == '\'' || c == '"') {
			quote = c
			continue
		}
		if c == quote {
			quote = 0
			continue
		}
		if c == '\\' && i + 1 < len(s) {
			n := s[i + 1]
			escapes := quote == 0 || n == '\\' || n == quote || (quote == '"' && n == '$')
			if escapes {
				strings.write_byte(&sb, n)
				i += 1
				continue
			}
		}
		strings.write_byte(&sb, c)
	}
	return strings.to_string(sb)
}

// classify_entry determines the source of an entry
// wayu_value is the value declared in wayu.toml (or empty string if not present)
// env_value is the value from the shell environment (or nil if not present)
// For aliases, pass empty wayu_value and check the aliases map directly.
classify_entry :: proc(name: string, wayu_value: string, env_value: Maybe(string)) -> EntrySource {
	has_wayu := wayu_value != ""
	has_env := env_value != nil

	if has_wayu && has_env {
		// Both present — check if they match (for values, not names)
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
	context.allocator = snapshot_allocator()
	for entry in ENV_SNAPSHOT_CACHE.path_entries {
		delete(entry)
	}
	delete(ENV_SNAPSHOT_CACHE.path_entries)
	for k, v in ENV_SNAPSHOT_CACHE.env_vars {
		delete(k)
		if s, ok := v.?; ok {
			crypto.zero_explicit(raw_data(s), len(s)) // may be a secret's value
			delete(s)
		}
	}
	delete(ENV_SNAPSHOT_CACHE.env_vars)
	for k, v in ENV_SNAPSHOT_CACHE.aliases {
		delete(k)
		delete(v)
	}
	delete(ENV_SNAPSHOT_CACHE.aliases)
	ENV_SNAPSHOT_CACHE = {}
}

// The snapshot is a process-lifetime cache, so it lives on the heap
// allocator rather than whatever context.allocator the first caller had
// (a unit test's tracking allocator reported it as that test's leak).
@(private = "file")
snapshot_allocator :: proc() -> runtime.Allocator {
	return runtime.heap_allocator()
}

// Does the snapshot hold a copy of `name`? (Tests: unrelated variables are
// never copied.)
env_snapshot_holds :: proc(name: string) -> bool {
	return name in ENV_SNAPSHOT_CACHE.env_vars
}
