// migrate_schema.odin - Upgrade obsolete wayu.toml schema in place.
//
// v3.x replaced the array-of-tables forms with single inline tables:
//
//   [[paths]]                 →  [paths]
//   path = "/usr/local/bin"      local_bin = "/usr/local/bin"
//
//   [[aliases]]               →  [aliases]
//   name = "ll"                  ll = "ls -la"
//   command = "ls -la"
//
//   [[constants]]             →  [env]
//   name = "EDITOR"              EDITOR = "nvim"
//   value = "nvim"
//
//   [constants]               →  [env]
//
// The migration is one-shot, idempotent, and leaves a backup. After it
// runs, the schema_check.odin guard in subsequent commands sees a clean
// file and proceeds normally.

package wayu

import "core:fmt"
import "core:os"
import "core:strings"

migrate_toml_schema :: proc(dry_run: bool) {
	toml_path := fmt.aprintf("%s/wayu.toml", g_ctx.wayu_config)
	defer delete(toml_path)

	if !os.exists(toml_path) {
		print_error("No wayu.toml found at %s", toml_path)
		os.exit(EXIT_NOINPUT)
	}

	content_bytes, ok := safe_read_file(toml_path)
	if !ok {
		print_error("Could not read %s", toml_path)
		os.exit(EXIT_IOERR)
	}
	defer delete(content_bytes)
	content := string(content_bytes)

	if len(detect_legacy_schema(content)) == 0 {
		print_success("wayu.toml already uses the modern schema — nothing to do")
		return
	}

	// Parse legacy sections out of the existing file.
	paths := parse_legacy_paths(content)
	defer { for p in paths { delete(p) }; delete(paths) }

	aliases := parse_legacy_aliases(content)
	defer {
		for a in aliases { delete(a.name); delete(a.command) }
		delete(aliases)
	}

	envs := parse_legacy_constants(content)
	defer {
		for e in envs { delete(e.name); delete(e.value) }
		delete(envs)
	}

	// Build the modernised file. Start by stripping every legacy section,
	// then append fresh modern blocks in canonical order.
	stripped := strip_legacy_sections(content)
	defer delete(stripped)

	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)
	fmt.sbprint(&builder, stripped)
	if !strings.has_suffix(stripped, "\n") { fmt.sbprint(&builder, "\n") }

	if len(paths) > 0 {
		fmt.sbprintln(&builder, "")
		fmt.sbprintln(&builder, "[paths]")
		taken := make(map[string]bool)
		defer delete(taken)
		// Emit in alphabetical key order for deterministic output.
		keyed := make([dynamic]struct{ key, path: string })
		defer {
			for kp in keyed { delete(kp.key) }
			delete(keyed)
		}
		for p in paths {
			k := derive_path_key(p, taken)
			taken[k] = true
			append(&keyed, struct{ key, path: string }{key = k, path = p})
		}
		// Sort by key.
		for i := 1; i < len(keyed); i += 1 {
			j := i
			for j > 0 && keyed[j-1].key > keyed[j].key {
				keyed[j-1], keyed[j] = keyed[j], keyed[j-1]
				j -= 1
			}
		}
		for kp in keyed {
			escaped := escape_toml_string(kp.path)
			fmt.sbprintfln(&builder, "%s = \"%s\"", kp.key, escaped)
			delete(escaped)
		}
	}

	if len(aliases) > 0 {
		// Sort alphabetically by name.
		sorted := make([dynamic]AliasEntry, 0, len(aliases))
		defer delete(sorted)
		for a in aliases { append(&sorted, a) }
		for i := 1; i < len(sorted); i += 1 {
			j := i
			for j > 0 && sorted[j-1].name > sorted[j].name {
				sorted[j-1], sorted[j] = sorted[j], sorted[j-1]
				j -= 1
			}
		}
		fmt.sbprintln(&builder, "")
		fmt.sbprintln(&builder, "[aliases]")
		for a in sorted {
			escaped := escape_toml_string(a.command)
			fmt.sbprintfln(&builder, "%s = \"%s\"", a.name, escaped)
			delete(escaped)
		}
	}

	if len(envs) > 0 {
		// Sort alphabetically by name.
		sorted := make([dynamic]EnvEntry, 0, len(envs))
		defer delete(sorted)
		for e in envs { append(&sorted, e) }
		for i := 1; i < len(sorted); i += 1 {
			j := i
			for j > 0 && sorted[j-1].name > sorted[j].name {
				sorted[j-1], sorted[j] = sorted[j], sorted[j-1]
				j -= 1
			}
		}
		fmt.sbprintln(&builder, "")
		fmt.sbprintln(&builder, "[env]")
		for e in sorted {
			escaped := escape_toml_string(e.value)
			fmt.sbprintfln(&builder, "%s = \"%s\"", e.name, escaped)
			delete(escaped)
		}
	}

	new_content := strings.to_string(builder)

	if dry_run {
		print_header("DRY RUN - schema migration preview", EMOJI_INFO)
		fmt.println()
		fmt.printfln("%sWould rewrite %s with:%s", BRIGHT_CYAN, toml_path, RESET)
		fmt.println()
		fmt.println(new_content)
		return
	}

	if !create_backup_cli(toml_path) {
		print_error("Could not back up %s — aborting", toml_path)
		os.exit(EXIT_IOERR)
	}
	if !safe_write_file(toml_path, transmute([]byte)new_content) {
		print_error("Could not write %s", toml_path)
		os.exit(EXIT_IOERR)
	}

	print_success("Schema upgraded — %d path(s), %d alias(es), %d env entr%s migrated",
		len(paths), len(aliases), len(envs), len(envs) == 1 ? "y" : "ies")
	fmt.printfln("Backup written under %s/backups/", g_ctx.wayu_config)
}

// ---------------------------------------------------------------------------
// Legacy-section parsers (used only by `wayu migrate --schema`)
// ---------------------------------------------------------------------------

// Collect path values from BOTH the legacy [[paths]] array-of-tables and any
// hand-written modern [paths] table. Returning the union lets the migration
// produce a single canonical [paths] section even when the source file has a
// half-applied mix of both forms.
parse_legacy_paths :: proc(content: string) -> [dynamic]string {
	paths := make([dynamic]string)
	lines := strings.split(content, "\n")
	defer delete(lines)

	// 1. [[paths]] array-of-tables (each block has a `path = "..."` line).
	{
		in_block := false
		for line in lines {
			trimmed := strings.trim_space(line)
			if trimmed == "[[paths]]" { in_block = true; continue }
			if strings.has_prefix(trimmed, "[") { in_block = false; continue }
			if !in_block { continue }
			if strings.has_prefix(trimmed, "path") {
				eq := strings.index_byte(trimmed, '=')
				if eq < 0 { continue }
				val := strings.trim_space(trimmed[eq+1:])
				val = strings.trim_prefix(val, `"`)
				val = strings.trim_suffix(val, `"`)
				if len(val) > 0 { append(&paths, strings.clone(val)) }
			}
		}
	}

	// 2. Modern [paths] table (key = "value"). De-duplicate against #1.
	{
		in_block := false
		for line in lines {
			trimmed := strings.trim_space(line)
			if trimmed == "[paths]" { in_block = true; continue }
			if strings.has_prefix(trimmed, "[") { in_block = false; continue }
			if !in_block { continue }
			if len(trimmed) == 0 || strings.has_prefix(trimmed, "#") { continue }
			eq := strings.index_byte(trimmed, '=')
			if eq < 1 { continue }
			val := strings.trim_space(trimmed[eq+1:])
			val = strings.trim_prefix(val, `"`)
			val = strings.trim_suffix(val, `"`)
			if len(val) == 0 { continue }
			dup := false
			for existing in paths {
				if existing == val { dup = true; break }
			}
			if !dup { append(&paths, strings.clone(val)) }
		}
	}
	return paths
}

// Same dual-form approach as parse_legacy_paths: collect from [[aliases]]
// blocks and any modern [aliases] table, dedupe by name (last write wins).
parse_legacy_aliases :: proc(content: string) -> [dynamic]AliasEntry {
	out := make([dynamic]AliasEntry)
	lines := strings.split(content, "\n")
	defer delete(lines)

	upsert :: proc(out: ^[dynamic]AliasEntry, name, cmd: string) {
		for &e in out {
			if e.name == name {
				delete(e.command)
				e.command = strings.clone(cmd)
				return
			}
		}
		append(out, AliasEntry{name = strings.clone(name), command = strings.clone(cmd)})
	}

	// 1. [[aliases]] array-of-tables.
	{
		in_block := false
		cur_name := ""
		cur_cmd  := ""
		flush :: proc(out: ^[dynamic]AliasEntry, name, cmd: ^string) {
			if len(name^) > 0 {
				for &e in out {
					if e.name == name^ {
						delete(e.command)
						e.command = strings.clone(cmd^)
						name^ = ""; cmd^ = ""
						return
					}
				}
				append(out, AliasEntry{name = strings.clone(name^), command = strings.clone(cmd^)})
			}
			name^ = ""; cmd^ = ""
		}
		for line in lines {
			trimmed := strings.trim_space(line)
			if trimmed == "[[aliases]]" {
				flush(&out, &cur_name, &cur_cmd)
				in_block = true
				continue
			}
			if strings.has_prefix(trimmed, "[") {
				if in_block { flush(&out, &cur_name, &cur_cmd) }
				in_block = false
				continue
			}
			if !in_block { continue }
			eq := strings.index_byte(trimmed, '=')
			if eq < 1 { continue }
			key := strings.trim_space(trimmed[:eq])
			val := strings.trim_space(trimmed[eq+1:])
			val = strings.trim_prefix(val, `"`)
			val = strings.trim_suffix(val, `"`)
			switch key {
			case "name":    cur_name = val
			case "command": cur_cmd  = val
			}
		}
		if in_block { flush(&out, &cur_name, &cur_cmd) }
	}

	// 2. Modern [aliases] table.
	{
		in_block := false
		for line in lines {
			trimmed := strings.trim_space(line)
			if trimmed == "[aliases]" { in_block = true; continue }
			if strings.has_prefix(trimmed, "[") { in_block = false; continue }
			if !in_block { continue }
			if len(trimmed) == 0 || strings.has_prefix(trimmed, "#") { continue }
			eq := strings.index_byte(trimmed, '=')
			if eq < 1 { continue }
			name := strings.trim_space(trimmed[:eq])
			val := strings.trim_space(trimmed[eq+1:])
			val = strings.trim_prefix(val, `"`)
			val = strings.trim_suffix(val, `"`)
			if len(name) == 0 { continue }
			upsert(&out, name, val)
		}
	}
	return out
}

// Same dual-form approach: collects from [[constants]], [constants], and
// any modern [env] table. Dedupes by name (last write wins).
parse_legacy_constants :: proc(content: string) -> [dynamic]EnvEntry {
	out := make([dynamic]EnvEntry)
	lines := strings.split(content, "\n")
	defer delete(lines)

	upsert :: proc(out: ^[dynamic]EnvEntry, name, value: string) {
		for &e in out {
			if e.name == name {
				delete(e.value)
				e.value = strings.clone(value)
				return
			}
		}
		append(out, EnvEntry{name = strings.clone(name), value = strings.clone(value)})
	}

	// [[constants]] array-of-tables
	{
		in_block := false
		cur_name := ""
		cur_val  := ""
		flush :: proc(out: ^[dynamic]EnvEntry, name, val: ^string) {
			if len(name^) > 0 {
				append(out, EnvEntry{name = strings.clone(name^), value = strings.clone(val^)})
			}
			name^ = ""; val^ = ""
		}
		for line in lines {
			trimmed := strings.trim_space(line)
			if trimmed == "[[constants]]" {
				flush(&out, &cur_name, &cur_val)
				in_block = true
				continue
			}
			if strings.has_prefix(trimmed, "[") {
				if in_block { flush(&out, &cur_name, &cur_val) }
				in_block = false
				continue
			}
			if !in_block { continue }
			eq := strings.index_byte(trimmed, '=')
			if eq < 1 { continue }
			key := strings.trim_space(trimmed[:eq])
			v := strings.trim_space(trimmed[eq+1:])
			v = strings.trim_prefix(v, `"`)
			v = strings.trim_suffix(v, `"`)
			switch key {
			case "name":  cur_name = v
			case "value": cur_val  = v
			}
		}
		if in_block { flush(&out, &cur_name, &cur_val) }
	}

	// [constants] table form (renamed to [env]) and modern [env] table.
	env_sections := []string{"[constants]", "[env]"}
	for section in env_sections {
		in_block := false
		for line in lines {
			trimmed := strings.trim_space(line)
			if trimmed == section { in_block = true; continue }
			if strings.has_prefix(trimmed, "[") { in_block = false; continue }
			if !in_block { continue }
			if len(trimmed) == 0 || strings.has_prefix(trimmed, "#") { continue }
			eq := strings.index_byte(trimmed, '=')
			if eq < 1 { continue }
			name := strings.trim_space(trimmed[:eq])
			v := strings.trim_space(trimmed[eq+1:])
			v = strings.trim_prefix(v, `"`)
			v = strings.trim_suffix(v, `"`)
			if len(name) == 0 { continue }
			upsert(&out, name, v)
		}
	}
	return out
}

// Section headers stripped during schema migration: every legacy form plus
// the modern targets, so a hand-written mix collapses cleanly into the
// single [paths]/[aliases]/[env] sections we re-emit afterwards.
MIGRATE_STRIP_HEADERS :: []string{
	"[[paths]]", "[paths]",
	"[[aliases]]", "[aliases]",
	"[[constants]]", "[constants]", "[env]",
}

// Strip every legacy + target section from `content`. A section runs from
// its header line through the line preceding the next `[` header.
// Caller owns the returned string.
strip_legacy_sections :: proc(content: string) -> string {
	lines := strings.split(content, "\n")
	defer delete(lines)

	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	in_strip := false
	is_strip_header :: proc(trimmed: string) -> bool {
		for h in MIGRATE_STRIP_HEADERS {
			if trimmed == h { return true }
		}
		return false
	}

	for line in lines {
		trimmed := strings.trim_space(line)
		if is_strip_header(trimmed) {
			in_strip = true
			continue
		}
		if strings.has_prefix(trimmed, "[") && !is_strip_header(trimmed) {
			in_strip = false
		}
		if in_strip { continue }
		fmt.sbprintln(&builder, line)
	}
	return strings.clone(strings.to_string(builder))
}
