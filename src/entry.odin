// entry.odin - Entry payload union and unified add/remove operations
//
// `Entry` is a sum type over the three entry kinds wayu manages: PATH directories,
// shell aliases, and exported constants. Each variant carries only the fields
// meaningful to that kind — no shared bag-of-strings struct, no unused `value`
// for PATH, no type tag a caller has to remember to set.
//
// Both CLI handlers and TUI views call `entry_add` / `entry_remove` with the
// appropriate variant. The procs route to the same TOML-first writers the CLI
// uses (toml_*_add / toml_*_remove) and trigger init-core regeneration so the
// shell sees the change on next reload — matching what `wayu path/alias/
// constants add` does on the command line.

package wayu

import "core:strings"

EntryPath :: struct {
	path: string,
}

EntryAlias :: struct {
	name:    string,
	command: string,
}

EntryConst :: struct {
	name:  string,
	value: string,
}

Entry :: union {
	EntryPath,
	EntryAlias,
	EntryConst,
}

// Add an entry to wayu.toml. Both CLI and TUI use this for mutations from
// outside the spec-driven dispatchers.
entry_add :: proc(entry: Entry) -> (bool, string) {
	old := g_ctx.dry_run
	g_ctx.dry_run = false
	defer { g_ctx.dry_run = old }

	switch e in entry {
	case EntryPath:
		// Validate path format (no existence check — TUI lets you stage a
		// path that doesn't exist yet, matching pre-bug TUI behavior).
		result := validate_path(e.path)
		if !result.valid {
			err := strings.clone(result.error_message)
			delete(result.error_message)
			return false, err
		}
		if len(result.warning) > 0 {
			delete(result.warning)
		}
		if !toml_path_add(e.path, "") {
			return false, strings.clone("failed to write path to wayu.toml")
		}
		regenerate_init_core_silently()
		return true, ""
	case EntryAlias:
		return toml_alias_add(ConfigEntry{type = .ALIAS, name = e.name, value = e.command})
	case EntryConst:
		return toml_constant_add(ConfigEntry{type = .CONSTANT, name = e.name, value = e.value})
	}
	return false, strings.clone("unknown entry type")
}

// Remove an entry by identity (path for EntryPath, name for the others).
// The non-identity fields on the variant are ignored.
entry_remove :: proc(entry: Entry) -> (bool, string) {
	old := g_ctx.dry_run
	g_ctx.dry_run = false
	defer { g_ctx.dry_run = old }

	switch e in entry {
	case EntryPath:
		if !toml_path_remove(e.path) {
			return false, strings.clone("failed to remove path from wayu.toml")
		}
		regenerate_init_core_silently()
		return true, ""
	case EntryAlias:
		return toml_alias_remove(e.name)
	case EntryConst:
		return toml_constant_remove(e.name)
	}
	return false, strings.clone("unknown entry type")
}
