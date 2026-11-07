// migrate.odin - Implementation of `wayu migrate`
//
// Extracted from main.odin (2026-04-24) per code review L1. Two distinct
// migration flows live here:
//
//   1. Legacy-to-TOML migration (`wayu migrate`, `wayu migrate --dry-run`)
//      converts old aliases.zsh/path.zsh/constants.zsh files into a single
//      wayu.toml and archives the originals as *.zsh.migrated.
//
//   2. Cross-shell migration (`wayu migrate --from <shell> --to <shell>`)
//      rewrites alias/export/set syntax between POSIX shells and Fish while
//      regenerating per-shell init files.
//
// The dispatcher (`handle_migrate_command`) picks between the two based on
// whether --from/--to are present.

package wayu
import "core:fmt"
import "core:os"
import "core:strings"
import "core:strconv"
handle_migrate_command :: proc(args: []string) {
	// Three flows: --schema (toml schema upgrade), --from/--to (shell
	// migration), or no flag (legacy shell-files → wayu.toml). Global flags
	// (--dry-run, --yes, ...) were already stripped by the CLI parser, so
	// anything left that we don't recognise is a usage error — it must NOT
	// fall through to the legacy migration, which archives files.
	has_from, has_to, has_schema, want_help := false, false, false, false
	from_shell := ShellType.UNKNOWN
	to_shell := ShellType.UNKNOWN
	from_arg, to_arg := "", ""

	i := 0
	for i < len(args) {
		arg := args[i]
		switch arg {
		case "--schema":
			has_schema = true
		case "--from", "--to":
			if i + 1 >= len(args) {
				fmt.eprintfln("Error: %s requires a shell argument (bash, zsh, or fish)", arg)
				print_migrate_help()
				os.exit(EXIT_USAGE)
			}
			if arg == "--from" {
				has_from = true
				from_arg = args[i + 1]
				from_shell = parse_shell_type(from_arg)
			} else {
				has_to = true
				to_arg = args[i + 1]
				to_shell = parse_shell_type(to_arg)
			}
			i += 1
		case "help", "-h", "--help":
			want_help = true
		case:
			fmt.eprintfln("Unknown migrate option: %s", arg)
			print_migrate_help()
			os.exit(EXIT_USAGE)
		}
		i += 1
	}

	if want_help {
		print_migrate_help()
		return
	}

	if has_schema {
		if has_from || has_to {
			fmt.eprintln("Error: --schema cannot be combined with --from/--to")
			os.exit(EXIT_USAGE)
		}
		migrate_toml_schema(wayu.dry_run)
		return
	}

	// Legacy config migration: `wayu migrate` (no flags) or `wayu migrate --dry-run`.
	if !has_from && !has_to {
		migrate_legacy_to_toml(wayu.dry_run)
		return
	}

	if !has_from {
		fmt.eprintln("Error: --to requires --from <shell> (bash, zsh, or fish)")
		print_migrate_help()
		os.exit(EXIT_USAGE)
	}
	if !has_to {
		fmt.eprintln("Error: --from requires --to <shell> (bash, zsh, or fish)")
		print_migrate_help()
		os.exit(EXIT_USAGE)
	}

	if from_shell == .UNKNOWN {
		fmt.eprintfln("Error: unknown --from shell %q (expected bash, zsh, or fish)", from_arg)
		os.exit(EXIT_USAGE)
	}
	if to_shell == .UNKNOWN {
		fmt.eprintfln("Error: unknown --to shell %q (expected bash, zsh, or fish)", to_arg)
		os.exit(EXIT_USAGE)
	}

	if from_shell == to_shell {
		fmt.eprintfln("Error: source and target shells cannot be the same")
		os.exit(EXIT_USAGE)
	}

	// Perform migration
	migrate_shell_config(from_shell, to_shell)
}

migrate_shell_config :: proc(from_shell: ShellType, to_shell: ShellType) {
	from_ext := get_shell_extension(from_shell)
	to_ext := get_shell_extension(to_shell)

	if wayu.dry_run {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.println()
	}
	fmt.printfln("Migrating from %s to %s...", get_shell_name(from_shell), get_shell_name(to_shell))

	config_types := []string{"path", "aliases", "constants", "init", "tools"}
	migrated_count := 0
	failed_count := 0

	for config_type in config_types {
		from_file := fmt.aprintf("%s/%s.%s", wayu.data, config_type, from_ext)
		to_file := fmt.aprintf("%s/%s.%s", wayu.data, config_type, to_ext)
		defer delete(from_file)
		defer delete(to_file)

		// Check if source file exists
		if !os.exists(from_file) {
			fmt.printfln("  Skipping %s.%s (file not found)", config_type, from_ext)
			continue
		}

		// Check if target file already exists
		if os.exists(to_file) {
			fmt.printfln("  Warning: %s.%s already exists, skipping migration", config_type, to_ext)
			continue
		}

		// Read source file
		data, read_err := os.read_entire_file(from_file, context.allocator)
		if read_err != nil {
			fmt.eprintfln("  Error: Failed to read %s", from_file)
			failed_count += 1
			continue
		}
		defer delete(data)

		content := string(data)

		// Convert shell-specific content
		migrated_content := convert_shell_content(content, from_shell, to_shell, config_type)
		defer delete(migrated_content)

		if wayu.dry_run {
			fmt.printfln("  Would migrate %s.%s → %s.%s", config_type, from_ext, config_type, to_ext)
			migrated_count += 1
			continue
		}

		// Write to target file
		write_err := os.write_entire_file(to_file, transmute([]byte)migrated_content)
		if write_err != nil {
			fmt.eprintfln("  Error: Failed to write %s", to_file)
			failed_count += 1
			continue
		}

		fmt.printfln("  ✓ Migrated %s.%s → %s.%s", config_type, from_ext, config_type, to_ext)
		migrated_count += 1
	}

	if wayu.dry_run {
		fmt.println()
		fmt.printfln("Would migrate %d configuration file(s).", migrated_count)
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
		return
	}

	if migrated_count > 0 {
		fmt.printfln("\nMigration completed! Migrated %d configuration file(s).", migrated_count)
		fmt.printfln("To use the new configuration:")
		#partial switch to_shell {
		case .BASH:
			fmt.printfln("  1. Add this line to your ~/.bashrc or ~/.bash_profile:")
			fmt.printfln("     source \"%s/init.bash\"", wayu.data)
		case .FISH:
			fmt.printfln("  1. Add this line to your ~/.config/fish/config.fish:")
			fmt.printfln("     source \"%s/init.fish\"", wayu.data)
		case:
			fmt.printfln("  1. Add this line to your ~/.zshrc:")
			fmt.printfln("     source \"%s/init.zsh\"", wayu.data)
		}
		fmt.printfln("  2. Restart your shell or source the RC file")
	} else {
		fmt.printfln("\nNo files were migrated. Check that source files exist and target files don't already exist.")
	}

	if failed_count > 0 {
		print_error("%d file(s) failed to migrate", failed_count)
		os.exit(EXIT_IOERR)
	}
}

// ---------------------------------------------------------------------------
// Cross-shell quoting helpers. Local to migrate so the conversion doesn't
// depend on shell.odin's generators. All return heap strings (caller frees).
// ---------------------------------------------------------------------------

// Which quote style a fish value was written in (fish keeps the quotes in
// the source line; parse_*_line strips them).
MigrateQuote :: enum { None, Single, Double }

// Detect the quote style of the value at the end of a fish line.
migrate_fish_value_quote :: proc(line: string) -> MigrateQuote {
	trimmed := strings.trim_space(line)
	if len(trimmed) == 0 { return .None }
	switch trimmed[len(trimmed) - 1] {
	case '\'': return .Single
	case '"':  return .Double
	}
	return .None
}

// Decode a fish single-quoted body: only `\\` and `\'` are escapes.
migrate_fish_sq_decode :: proc(raw: string) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	i := 0
	for i < len(raw) {
		if raw[i] == '\\' && i + 1 < len(raw) && (raw[i+1] == '\\' || raw[i+1] == '\'') {
			strings.write_byte(&b, raw[i+1])
			i += 2
			continue
		}
		strings.write_byte(&b, raw[i])
		i += 1
	}
	return strings.clone(strings.to_string(b))
}

// Decode a POSIX double-quoted body into the literal text it denotes,
// ignoring expansions (used for alias bodies, which are re-evaluated when
// the alias runs).
migrate_posix_dq_decode :: proc(raw: string) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	i := 0
	for i < len(raw) {
		if raw[i] == '\\' && i + 1 < len(raw) {
			switch raw[i+1] {
			case '\\', '"', '$', '`':
				strings.write_byte(&b, raw[i+1])
				i += 2
				continue
			}
		}
		strings.write_byte(&b, raw[i])
		i += 1
	}
	return strings.clone(strings.to_string(b))
}

// Literal text → fish single-quoted word (no expansion).
migrate_fish_sq_quote :: proc(s: string) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_byte(&b, '\'')
	for i in 0..<len(s) {
		if s[i] == '\\' || s[i] == '\'' { strings.write_byte(&b, '\\') }
		strings.write_byte(&b, s[i])
	}
	strings.write_byte(&b, '\'')
	return strings.clone(strings.to_string(b))
}

// Literal text → POSIX double-quoted word (no expansion).
migrate_posix_dq_quote :: proc(s: string) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_byte(&b, '"')
	for i in 0..<len(s) {
		switch s[i] {
		case '\\', '"', '$', '`': strings.write_byte(&b, '\\')
		}
		strings.write_byte(&b, s[i])
	}
	strings.write_byte(&b, '"')
	return strings.clone(strings.to_string(b))
}

// POSIX double-quoted body → fish double-quoted word, preserving `$VAR`
// expansion. `${NAME}` (invalid in fish) becomes `{$NAME}`; `\`` becomes a
// plain backtick (literal in fish). `\"`, `\\`, `\$` mean the same in both.
migrate_posix_dq_to_fish_dq :: proc(raw: string) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_byte(&b, '"')
	i := 0
	for i < len(raw) {
		c := raw[i]
		if c == '\\' && i + 1 < len(raw) {
			if raw[i+1] == '`' {
				strings.write_byte(&b, '`')
			} else {
				strings.write_byte(&b, c)
				strings.write_byte(&b, raw[i+1])
			}
			i += 2
			continue
		}
		if c == '$' && i + 1 < len(raw) && raw[i+1] == '{' {
			if close := strings.index_byte(raw[i+2:], '}'); close > 0 {
				strings.write_string(&b, "{$"); strings.write_string(&b, raw[i+2:i+2+close]); strings.write_byte(&b, '}')
				i += 2 + close + 1
				continue
			}
		}
		if c == '"' {
			// Unbalanced quote that slipped through the parser — escape it.
			strings.write_byte(&b, '\\')
		}
		strings.write_byte(&b, c)
		i += 1
	}
	strings.write_byte(&b, '"')
	return strings.clone(strings.to_string(b))
}

// fish double-quoted (or bare) body → POSIX double-quoted word, preserving
// `$VAR` expansion. `{$NAME}` becomes `${NAME}`; backticks (literal in fish)
// are escaped; a bare `"` is escaped.
migrate_fish_dq_to_posix_dq :: proc(raw: string) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_byte(&b, '"')
	i := 0
	for i < len(raw) {
		c := raw[i]
		if c == '\\' && i + 1 < len(raw) {
			strings.write_byte(&b, c)
			strings.write_byte(&b, raw[i+1])
			i += 2
			continue
		}
		if c == '{' && i + 1 < len(raw) && raw[i+1] == '$' {
			if close := strings.index_byte(raw[i+2:], '}'); close > 0 {
				strings.write_string(&b, "${"); strings.write_string(&b, raw[i+2:i+2+close]); strings.write_byte(&b, '}')
				i += 2 + close + 1
				continue
			}
		}
		if c == '`' || c == '"' {
			strings.write_byte(&b, '\\')
		}
		strings.write_byte(&b, c)
		i += 1
	}
	strings.write_byte(&b, '"')
	return strings.clone(strings.to_string(b))
}

// Convert a fish value (as captured by parse_*_line, quotes stripped) to a
// POSIX double-quoted word, honouring the original quote style.
migrate_fish_value_to_posix :: proc(raw: string, quote: MigrateQuote) -> string {
	if quote == .Single {
		lit := migrate_fish_sq_decode(raw)
		defer delete(lit)
		return migrate_posix_dq_quote(lit)
	}
	return migrate_fish_dq_to_posix_dq(raw)
}

// Extract PATH entries from a path.<ext> file in either dialect. Returns
// already-target-quoted words for `to_shell`. Caller frees each + slice.
migrate_collect_path_words :: proc(content: string, from_shell, to_shell: ShellType) -> [dynamic]string {
	out := make([dynamic]string)
	lines := strings.split_lines(content)
	defer delete(lines)

	for line in lines {
		trimmed := strings.trim_space(line)
		raw: string
		quote := MigrateQuote.Double
		found := false

		if from_shell == .FISH {
			rest := ""
			if strings.has_prefix(trimmed, "set -a WAYU_PATHS ") {
				rest = strings.trim_space(trimmed[len("set -a WAYU_PATHS "):])
			} else if strings.has_prefix(trimmed, "fish_add_path ") {
				rest = strings.trim_space(trimmed[len("fish_add_path "):])
				for strings.has_prefix(rest, "-") {
					sp := strings.index_byte(rest, ' ')
					if sp == -1 { rest = ""; break }
					rest = strings.trim_space(rest[sp+1:])
				}
			}
			if len(rest) == 0 { continue }
			quote = .None
			if len(rest) >= 2 && (rest[0] == '\'' || rest[0] == '"') && rest[0] == rest[len(rest)-1] {
				quote = rest[0] == '\'' ? .Single : .Double
				rest = rest[1:len(rest)-1]
			}
			raw = rest
			found = true
		} else {
			// POSIX: array element lines `"dir"` inside WAYU_PATHS=( ... ).
			if len(trimmed) >= 2 && trimmed[0] == '"' && trimmed[len(trimmed)-1] == '"' {
				raw = trimmed[1:len(trimmed)-1]
				found = true
			}
		}
		if !found { continue }

		word: string
		if to_shell == .FISH {
			word = migrate_posix_dq_to_fish_dq(raw)
		} else if from_shell == .FISH {
			word = migrate_fish_value_to_posix(raw, quote)
		} else {
			word = fmt.aprintf(`"%s"`, raw) // POSIX → POSIX: same syntax
		}
		append(&out, word)
	}
	return out
}

// Render a complete path.<ext> for `to_shell` from the shell's template,
// inserting `words` into the WAYU_PATHS registry.
migrate_render_path_file :: proc(words: []string, to_shell: ShellType) -> string {
	template := get_path_template(to_shell)
	lines := strings.split_lines(template)
	defer delete(lines)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for line, i in lines {
		strings.write_string(&b, line)
		if i < len(lines) - 1 { strings.write_byte(&b, '\n') }
		trimmed := strings.trim_space(line)
		if to_shell == .FISH && trimmed == "set -gx WAYU_PATHS" {
			for w in words { fmt.sbprintf(&b, "set -a WAYU_PATHS %s\n", w) }
		} else if to_shell != .FISH && trimmed == "WAYU_PATHS=(" {
			for w in words { fmt.sbprintf(&b, "  %s\n", w) }
		}
	}
	return strings.clone(strings.to_string(b))
}

convert_shell_content :: proc(content: string, from_shell: ShellType, to_shell: ShellType, config_type: string) -> string {
	// path.<ext> is a wayu-managed registry: its loop/dedup code is
	// dialect-specific (zsh array syntax is invalid in fish, the zsh
	// `${(s/:/)PATH}` split is invalid in bash), so rebuild it from the
	// target template instead of translating line by line.
	if config_type == "path" {
		words := migrate_collect_path_words(content, from_shell, to_shell)
		defer {
			for w in words { delete(w) }
			delete(words)
		}
		return migrate_render_path_file(words[:], to_shell)
	}

	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	lines := strings.split_lines(content)
	defer delete(lines)

	for line, i in lines {
		converted_line := line
		owned := ""

		// Convert shebang
		if strings.has_prefix(line, "#!/usr/bin/env") {
			#partial switch to_shell {
			case .BASH: converted_line = "#!/usr/bin/env bash"
			case .FISH: converted_line = "#!/usr/bin/env fish"
			case: converted_line = "#!/usr/bin/env zsh"
			}
		} else if to_shell == .FISH && (from_shell == .BASH || from_shell == .ZSH) {
			// POSIX → fish. Alias bodies are literal command text, so decode
			// and re-quote for fish single quotes; constants keep $VAR
			// expansion via fish double quotes.
			if entry, ok := parse_alias_line(line); ok {
				lit := migrate_posix_dq_decode(entry.value)
				q := migrate_fish_sq_quote(lit)
				owned = fmt.aprintf("alias %s %s", entry.name, q)
				delete(q); delete(lit)
				cleanup_entry(&entry)
			} else if entry, ok := parse_constant_line(line); ok {
				q := migrate_posix_dq_to_fish_dq(entry.value)
				owned = fmt.aprintf("set -gx %s %s", entry.name, q)
				delete(q)
				cleanup_entry(&entry)
			}
		} else if from_shell == .FISH && (to_shell == .BASH || to_shell == .ZSH) {
			// fish → POSIX, honouring the fish quote style.
			if entry, ok := parse_alias_line(line); ok {
				quote := migrate_fish_value_quote(line)
				lit := quote == .Single ? migrate_fish_sq_decode(entry.value) : strings.clone(entry.value)
				q := migrate_posix_dq_quote(lit)
				owned = fmt.aprintf("alias %s=%s", entry.name, q)
				delete(q); delete(lit)
				cleanup_entry(&entry)
			} else if entry, ok := parse_constant_line(line); ok {
				q := migrate_fish_value_to_posix(entry.value, migrate_fish_value_quote(line))
				owned = fmt.aprintf("export %s=%s", entry.name, q)
				delete(q)
				cleanup_entry(&entry)
			}
		}
		if len(owned) > 0 { converted_line = owned }

		strings.write_string(&builder, converted_line)
		if i < len(lines) - 1 {
			strings.write_string(&builder, "\n")
		}
		if len(owned) > 0 { delete(owned) }
	}

	return strings.clone(strings.to_string(builder))
}

// Migrate legacy shell configs to TOML format
migrate_legacy_to_toml :: proc(dry_run: bool) {
	print_header("Legacy Config Migration", "🔄")
	fmt.println()

	// Check which legacy files exist
	legacy_files := []string{"aliases", "constants", "path"}
	found_files := make([dynamic]string)
	defer delete(found_files)

	// Only consider a legacy file "found" when it contains at least one line
	// that parses as real legacy content (a path entry, an alias definition,
	// or an export). wayu's setup pass scaffolds path.zsh with helper shell
	// code (WAYU_PATHS=(), dedup loop, …) and touches empty constants.zsh
	// files on every CLI invocation, so a plain non-comment line counter
	// would report every install as "has legacy content to migrate".
	has_parseable_legacy :: proc(path: string, kind: string) -> bool {
		content, ok := safe_read_file(path)
		if !ok { return false }
		defer delete(content)
		lines := strings.split(string(content), "\n")
		defer delete(lines)
		for line in lines {
			switch kind {
			case "path":
				entry, p_ok := parse_path_line(line)
				if p_ok { cleanup_entry(&entry); return true }
			case "aliases":
				entry, p_ok := parse_alias_line(line)
				if p_ok { cleanup_entry(&entry); return true }
			case "constants":
				entry, p_ok := parse_constant_line(line)
				if p_ok { cleanup_entry(&entry); return true }
			}
		}
		return false
	}

	for file in legacy_files {
		config_file := fmt.aprintf("%s/%s.%s", wayu.data, file, wayu.shell_ext)
		defer delete(config_file)

		if os.exists(config_file) && has_parseable_legacy(config_file, file) {
			append(&found_files, file)
		}
	}

	if len(found_files) == 0 {
		print_success("No legacy shell config files found")
		fmt.println("Your configuration is already organized or empty.")
		return
	}

	print_header("Found Legacy Files", "📋")
	for file in found_files {
		fmt.printfln("  • %s.%s", file, wayu.shell_ext)
	}
	fmt.println()

	// Show what would be imported
	fmt.printfln("These files contain shell-specific syntax. Converting to TOML requires:")
	fmt.println("  • Parsing alias definitions (name=value)")
	fmt.println("  • Parsing export statements (name=value)")
	fmt.println("  • Normalizing PATH entries")
	fmt.println()

	if dry_run {
		print_info("Dry-run mode: would parse %d legacy files", len(found_files))
		fmt.println()
		fmt.printfln("Sample extraction plan:")

		// Show sample of what would be extracted from aliases
		has_aliases := false
		for f in found_files {
			if f == "aliases" {
				has_aliases = true
				break
			}
		}
		if has_aliases {
			aliases_file := fmt.aprintf("%s/aliases.%s", wayu.data, wayu.shell_ext)
			defer delete(aliases_file)

			content, ok := safe_read_file(aliases_file)
			if ok {
				lines := strings.split(string(content), "\n")
				defer delete(lines)

				fmt.println()
				fmt.println("  [aliases]")
				count := 0
				for line in lines {
					trimmed := strings.trim_space(line)
					if len(trimmed) == 0 || strings.has_prefix(trimmed, "#") {
						continue
					}

					if strings.contains(trimmed, "alias ") {
						// Simple parsing: alias name='value'
						rest := strings.trim_prefix(trimmed, "alias ")
						if pos := strings.index(rest, "="); pos > 0 {
							name := rest[:pos]
							fmt.printfln("    # %s = ...", name)
							count += 1
							if count >= 3 {
								break
							}
						}
					}
				}
				delete(content)
				if count == 0 {
					fmt.println("    # (no parseable aliases found)")
				}
			}
		}

		fmt.println()
		fmt.printfln("Run %swayu migrate%s (without --dry-run) for actual migration", get_primary(), RESET)
		return
	}

	// ===== Real migration =====
	// Strategy: parse each legacy file line-by-line using the per-type spec
	// parser, then call the toml_*_add helpers so wayu.toml stays in its
	// canonical format. toml_*_add already creates timestamped backups of
	// wayu.toml on each write, so the user can always roll back.
	// Legacy files are renamed to .migrated so a subsequent run is a no-op
	// and the original content stays on disk for inspection.

	// Ensure wayu.toml exists — toml_*_add expects it to be readable.
	toml_path := fmt.aprintf("%s/%s", wayu.config, WAYU_TOML)
	defer delete(toml_path)
	if !os.exists(toml_path) {
		// Seed a minimal scaffold so toml_*_add has a file to append to.
		scaffold := "# wayu configuration (auto-generated by migrate)\n"
		if os.write_entire_file(toml_path, transmute([]byte)scaffold, SECRET_FILE_PERMS) != nil {
			print_error("Failed to create %s before migration", toml_path)
			return
		}
	}

	migrated_paths     := 0
	migrated_aliases   := 0
	migrated_constants := 0
	total_failed       := 0
	kept_files         := 0

	for file in found_files {
		legacy_file := fmt.aprintf("%s/%s.%s", wayu.data, file, wayu.shell_ext)
		defer delete(legacy_file)

		content, ok := safe_read_file(legacy_file)
		if !ok {
			print_warning("Could not read %s — skipping", legacy_file)
			total_failed += 1
			kept_files += 1
			continue
		}

		lines := strings.split(string(content), "\n")
		failed := 0

		switch file {
		case "path":
			for line in lines {
				entry, parsed := parse_path_line(line)
				if !parsed { continue }
				if toml_path_add(entry.name) {
					migrated_paths += 1
				} else {
					print_warning("Failed to migrate path %s", entry.name)
					failed += 1
				}
				cleanup_entry(&entry)
			}
		case "aliases":
			for line in lines {
				entry, parsed := parse_alias_line(line)
				if !parsed { continue }
				ok_add, err_msg := toml_alias_add(entry)
				if ok_add {
					migrated_aliases += 1
				} else {
					failed += 1
					if len(err_msg) > 0 {
						print_warning("Failed to migrate alias %s: %s", entry.name, err_msg)
						delete(err_msg)
					} else {
						print_warning("Failed to migrate alias %s", entry.name)
					}
				}
				cleanup_entry(&entry)
			}
		case "constants":
			for line in lines {
				entry, parsed := parse_constant_line(line)
				if !parsed { continue }
				ok_add, err_msg := toml_constant_add(entry)
				if ok_add {
					migrated_constants += 1
				} else {
					failed += 1
					if len(err_msg) > 0 {
						print_warning("Failed to migrate constant %s: %s", entry.name, err_msg)
						delete(err_msg)
					} else {
						print_warning("Failed to migrate constant %s", entry.name)
					}
				}
				cleanup_entry(&entry)
			}
		}

		delete(lines)
		delete(content)

		// Only archive when every entry made it into wayu.toml — otherwise
		// the legacy file is the only remaining copy of the failed entries.
		if failed > 0 {
			total_failed += failed
			kept_files += 1
			print_warning("%d entr%s from %s failed — left it in place (not archived)",
				failed, failed == 1 ? "y" : "ies", legacy_file)
			continue
		}

		// Rename legacy file to `.migrated` so a re-run is a clean no-op.
		archived := fmt.aprintf("%s.migrated", legacy_file)
		defer delete(archived)
		if rename_err := os.rename(legacy_file, archived); rename_err != nil {
			print_warning("Could not archive %s (error %v) — delete manually after reviewing", legacy_file, rename_err)
		} else {
			print_info("Archived %s → %s.migrated", legacy_file, file)
		}
	}

	fmt.println()
	if total_failed > 0 {
		print_error("Migration incomplete: %d paths, %d aliases, %d constants migrated; %d entr%s failed",
			migrated_paths, migrated_aliases, migrated_constants, total_failed, total_failed == 1 ? "y" : "ies")
		fmt.printfln("%d legacy file(s) were left in place. Fix the entries above and re-run %swayu migrate%s.",
			kept_files, get_primary(), RESET)
		os.exit(EXIT_DATAERR)
	}
	print_success("Migration complete: %d paths, %d aliases, %d constants", migrated_paths, migrated_aliases, migrated_constants)
	fmt.println()
	fmt.printfln("Review the result with %swayu toml show%s", get_primary(), RESET)
	fmt.printfln("Legacy files preserved as *.%s.migrated (safe to delete once verified)", wayu.shell_ext)
}

print_migrate_help :: proc() {
	// Title
	fmt.printf("\n%s%swayu migrate - Migrate configuration%s\n\n", BOLD, get_primary(), RESET)

	// Usage section
	fmt.printf("%s%sUSAGE:%s\n", BOLD, get_secondary(), RESET)
	fmt.println("  wayu migrate                         # Legacy file layout → wayu.toml")
	fmt.println("  wayu migrate --dry-run               # Preview legacy → TOML conversion")
	fmt.println("  wayu migrate --from <shell> --to <shell>   # Cross-shell migration")
	fmt.println("  wayu migrate --schema                # Upgrade obsolete wayu.toml schema")

	// Options section
	fmt.printf("\n%s%sOPTIONS:%s\n", BOLD, get_secondary(), RESET)
	fmt.println("  --dry-run, -n        Preview without modifying files (all modes)")
	fmt.println("  --schema             Rewrite [[paths]]/[[aliases]]/[[constants]] as tables")
	fmt.println("  --from <shell>       Source shell (bash, zsh, or fish) for cross-shell mode")
	fmt.println("  --to <shell>         Target shell (bash, zsh, or fish) for cross-shell mode")
	fmt.println("  help, -h, --help     Show this help message")

	// Examples section
	fmt.printf("\n%s%sEXAMPLES:%s\n", BOLD, get_secondary(), RESET)
	fmt.printf("  %s# Convert legacy aliases.zsh/path.zsh/constants.zsh into wayu.toml%s\n", get_muted(), RESET)
	fmt.printf("  %swayu migrate%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Preview only, no writes%s\n", get_muted(), RESET)
	fmt.printf("  %swayu migrate --dry-run%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Migrate ZSH config to Bash (cross-shell)%s\n", get_muted(), RESET)
	fmt.printf("  %swayu migrate --from zsh --to bash%s\n", get_muted(), RESET)

	// Notes section
	fmt.printf("\n%s%sNOTES:%s\n", BOLD, get_secondary(), RESET)
	fmt.printf("  %s• Legacy migration archives source files as *.%s.migrated%s\n", get_muted(), wayu.shell_ext, RESET)
	fmt.printf("  %s• Legacy files are only archived when every entry migrated successfully%s\n", get_muted(), RESET)
	fmt.printf("  %s• wayu.toml is backed up before every write (~/.config/wayu/backup/)%s\n", get_muted(), RESET)
	fmt.printf("  %s• Cross-shell mode creates new shell-specific config files%s\n", get_muted(), RESET)
	fmt.printf("  %s• You may need to update your shell RC file after cross-shell migration%s\n", get_muted(), RESET)
	fmt.println()
}
migrate_toml_schema :: proc(dry_run: bool) {
	toml_path := fmt.aprintf("%s/wayu.toml", wayu.config)
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
	defer { for p in paths { delete(p.key); delete(p.path) }; delete(paths) }

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

	// wayu only reads bare keys; refuse rather than silently renaming an
	// alias/constant whose name isn't one.
	bad_keys := make([dynamic]string)
	defer delete(bad_keys)
	for a in aliases { if !toml_key_is_plain(a.name) { append(&bad_keys, a.name) } }
	for e in envs    { if !toml_key_is_plain(e.name) { append(&bad_keys, e.name) } }
	if len(bad_keys) > 0 {
		print_error("Cannot migrate entries whose names are not plain TOML keys (A-Z a-z 0-9 _ -):")
		for k in bad_keys { fmt.eprintfln("  • %s", k) }
		fmt.eprintln("Rename them in wayu.toml and re-run `wayu migrate --schema`.")
		os.exit(EXIT_DATAERR)
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
		sorted := make([dynamic]TomlPathEntry, 0, len(paths))
		defer delete(sorted)
		for p in paths { append(&sorted, p) }
		slice_sort_path_entries(sorted[:])
		body := render_keyed_body(sorted[:])
		defer { for l in body { delete(l) }; delete(body) }
		for l in body { fmt.sbprintln(&builder, l) }
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

	if !toml_content_is_sane(new_content) {
		print_error("Schema migration produced invalid TOML — aborting without writing")
		fmt.eprintln("Please report this with a copy of your wayu.toml.")
		os.exit(EXIT_DATAERR)
	}

	if dry_run {
		print_header("DRY RUN - schema migration preview", EMOJI_INFO)
		fmt.println()
		fmt.printfln("%sWould rewrite %s with:%s", BRIGHT_CYAN, toml_path, RESET)
		fmt.println()
		preview := mask_toml_env_section(new_content, context.temp_allocator)
		fmt.println(preview)
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
	fmt.printfln("Backup written under %s/backup/", wayu.data)
}

// ---------------------------------------------------------------------------
// Minimal TOML key/value line parser (used only by `wayu migrate --schema`)
// ---------------------------------------------------------------------------

// Parse one `key = value` line. Handles bare and quoted keys, basic strings
// ("..." with escapes), literal strings ('...', no escapes), bare scalars
// (numbers/booleans, kept verbatim) and trailing `# comments`. Returns the
// DECODED key and value (heap, caller frees) so re-serialising with
// escape_toml_string never double-escapes. Multi-line strings and inline
// tables/arrays are not supported (ok=false).
migrate_parse_toml_kv :: proc(line: string) -> (key: string, value: string, ok: bool) {
	s := strings.trim_space(line)
	if len(s) == 0 || s[0] == '#' || s[0] == '[' { return }

	rest: string
	if s[0] == '"' || s[0] == '\'' {
		k, after, k_ok := migrate_parse_toml_string(s)
		if !k_ok { return }
		rest = strings.trim_left_space(after)
		if len(rest) == 0 || rest[0] != '=' { delete(k); return }
		key = k
		rest = rest[1:]
	} else {
		eq := strings.index_byte(s, '=')
		if eq < 1 { return }
		key = strings.clone(strings.trim_space(s[:eq]))
		rest = s[eq+1:]
	}

	rest = strings.trim_left_space(rest)
	if len(rest) == 0 { delete(key); key = ""; return }

	tail: string
	switch rest[0] {
	case '"', '\'':
		if strings.has_prefix(rest, `"""`) || strings.has_prefix(rest, "'''") {
			delete(key); key = ""; return
		}
		v, after, v_ok := migrate_parse_toml_string(rest)
		if !v_ok { delete(key); key = ""; return }
		value = v
		tail = after
	case '[', '{':
		delete(key); key = ""; return
	case:
		// Bare scalar: runs up to an inline comment.
		end := strings.index_byte(rest, '#')
		if end < 0 { end = len(rest) }
		value = strings.clone(strings.trim_space(rest[:end]))
		tail = rest[end:]
	}

	tail = strings.trim_space(tail)
	if len(tail) > 0 && tail[0] != '#' {
		delete(key); delete(value); key = ""; value = ""
		return
	}
	return key, value, true
}

// Parse a TOML basic ("...") or literal ('...') string at the start of `s`.
// Returns the decoded string (heap) and the remainder after the closing
// quote. Byte-oriented so multi-byte UTF-8 passes through untouched.
migrate_parse_toml_string :: proc(s: string) -> (decoded: string, rest: string, ok: bool) {
	if len(s) == 0 { return }
	q := s[0]
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	i := 1
	if q == '\'' {
		for i < len(s) {
			if s[i] == '\'' {
				return strings.clone(strings.to_string(b)), s[i+1:], true
			}
			strings.write_byte(&b, s[i])
			i += 1
		}
		return
	}

	for i < len(s) {
		c := s[i]
		if c == '"' {
			return strings.clone(strings.to_string(b)), s[i+1:], true
		}
		if c == '\\' && i + 1 < len(s) {
			switch s[i+1] {
			case '\\': strings.write_byte(&b, '\\')
			case '"':  strings.write_byte(&b, '"')
			case 'n':  strings.write_byte(&b, '\n')
			case 'r':  strings.write_byte(&b, '\r')
			case 't':  strings.write_byte(&b, '\t')
			case 'b':  strings.write_byte(&b, '\b')
			case 'f':  strings.write_byte(&b, '\f')
			case 'u', 'U':
				width := s[i+1] == 'u' ? 4 : 8
				if i + 2 + width > len(s) { return }
				cp, cp_ok := strconv.parse_u64_of_base(s[i+2:i+2+width], 16)
				if !cp_ok { return }
				strings.write_rune(&b, rune(cp))
				i += 2 + width
				continue
			case:
				// Invalid escape in TOML; keep it verbatim rather than lose data.
				strings.write_byte(&b, '\\')
				strings.write_byte(&b, s[i+1])
			}
			i += 2
			continue
		}
		strings.write_byte(&b, c)
		i += 1
	}
	return
}

// Collect path entries from BOTH the legacy [[paths]] array-of-tables and any
// hand-written modern [paths] table, preserving the user's [paths] key names.
// [[paths]] blocks may carry a `name`/`key` field, which becomes the key;
// otherwise one is derived. De-duplicated by path value (first wins, modern
// [paths] entries take precedence). Caller frees key+path of each + slice.
parse_legacy_paths :: proc(content: string) -> [dynamic]TomlPathEntry {
	out := make([dynamic]TomlPathEntry)
	lines := strings.split(content, "\n")
	defer delete(lines)

	taken := make(map[string]bool)
	defer delete(taken)

	has_path :: proc(out: []TomlPathEntry, p: string) -> bool {
		for e in out { if e.path == p { return true } }
		return false
	}

	// 1. Modern [paths] table — keys are user-chosen; keep them verbatim.
	{
		in_block := false
		for line in lines {
			trimmed := strings.trim_space(line)
			if trimmed == "[paths]" { in_block = true; continue }
			if strings.has_prefix(trimmed, "[") { in_block = false; continue }
			if !in_block { continue }
			k, v, ok := migrate_parse_toml_kv(trimmed)
			if !ok { continue }
			if len(v) == 0 || has_path(out[:], v) || k in taken {
				delete(k); delete(v)
				continue
			}
			taken[k] = true
			append(&out, TomlPathEntry{key = k, path = v})
		}
	}

	// 2. [[paths]] array-of-tables.
	Pending :: struct { name, path: string }
	pending := make([dynamic]Pending)
	defer delete(pending)
	{
		in_block := false
		cur: Pending
		flush :: proc(pending: ^[dynamic]Pending, cur: ^Pending) {
			if len(cur.path) > 0 {
				append(pending, cur^)
			} else {
				delete(cur.name)
			}
			cur^ = {}
		}
		for line in lines {
			trimmed := strings.trim_space(line)
			if trimmed == "[[paths]]" {
				if in_block { flush(&pending, &cur) }
				in_block = true
				continue
			}
			if strings.has_prefix(trimmed, "[") {
				if in_block { flush(&pending, &cur) }
				in_block = false
				continue
			}
			if !in_block { continue }
			k, v, ok := migrate_parse_toml_kv(trimmed)
			if !ok { continue }
			switch k {
			case "path":
				delete(cur.path); cur.path = v
			case "name", "key":
				delete(cur.name); cur.name = v
			case:
				delete(v)
			}
			delete(k)
		}
		if in_block { flush(&pending, &cur) }
	}

	// Explicit names first (so derived keys can't steal them), then derive.
	for &p in pending {
		if has_path(out[:], p.path) { delete(p.name); p.name = ""; delete(p.path); p.path = ""; continue }
		if len(p.name) == 0 { continue }
		k := sanitize_path_key(p.name)
		delete(p.name); p.name = ""
		if len(k) == 0 || k in taken { delete(k); continue }
		taken[k] = true
		append(&out, TomlPathEntry{key = k, path = p.path})
		p.path = ""
	}
	for &p in pending {
		if len(p.path) == 0 { continue }
		if has_path(out[:], p.path) { delete(p.path); continue }
		k := derive_path_key(p.path, taken)
		taken[k] = true
		append(&out, TomlPathEntry{key = k, path = p.path})
	}
	return out
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
			if len(name^) > 0 { upsert(out, name^, cmd^) }
			delete(name^); delete(cmd^)
			name^ = ""; cmd^ = ""
		}
		for line in lines {
			trimmed := strings.trim_space(line)
			if trimmed == "[[aliases]]" {
				if in_block { flush(&out, &cur_name, &cur_cmd) }
				in_block = true
				continue
			}
			if strings.has_prefix(trimmed, "[") {
				if in_block { flush(&out, &cur_name, &cur_cmd) }
				in_block = false
				continue
			}
			if !in_block { continue }
			key, val, ok := migrate_parse_toml_kv(trimmed)
			if !ok { continue }
			switch key {
			case "name":    delete(cur_name); cur_name = val
			case "command": delete(cur_cmd);  cur_cmd  = val
			case:           delete(val)
			}
			delete(key)
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
			name, val, ok := migrate_parse_toml_kv(trimmed)
			if !ok { continue }
			if len(name) > 0 { upsert(&out, name, val) }
			delete(name); delete(val)
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
			if len(name^) > 0 { upsert(out, name^, val^) }
			delete(name^); delete(val^)
			name^ = ""; val^ = ""
		}
		for line in lines {
			trimmed := strings.trim_space(line)
			if trimmed == "[[constants]]" {
				if in_block { flush(&out, &cur_name, &cur_val) }
				in_block = true
				continue
			}
			if strings.has_prefix(trimmed, "[") {
				if in_block { flush(&out, &cur_name, &cur_val) }
				in_block = false
				continue
			}
			if !in_block { continue }
			key, v, ok := migrate_parse_toml_kv(trimmed)
			if !ok { continue }
			switch key {
			case "name":  delete(cur_name); cur_name = v
			case "value": delete(cur_val);  cur_val  = v
			case:         delete(v)
			}
			delete(key)
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
			name, v, ok := migrate_parse_toml_kv(trimmed)
			if !ok { continue }
			if len(name) > 0 { upsert(&out, name, v) }
			delete(name); delete(v)
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
