// migrate.odin - Implementation of `wayu migrate`
//
// Extracted from main.odin (2026-04-24) per code review L1. Two distinct
// migration flows live here:
//
//   1. Legacy-to-TOML migration (`wayu migrate`, `wayu migrate --dry-run`)
//      converts old aliases.zsh/path.zsh/constants.zsh files into a single
//      wayu.toml and archives the originals as *.zsh.migrated. Parsing lives
//      in migrate_parse.odin (on top of the shell_words.odin tokenizer).
//
//   2. Cross-shell migration (`wayu migrate --from <shell> --to <shell>`)
//      switches [shell].type and regenerates the target shell's files from
//      wayu.toml.
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

// Cross-shell migration. wayu.toml is the source of truth, so switching
// shells means: record the new shell in [shell].type, make sure the target's
// init.<ext> orchestrator exists, and regenerate core/lazy/login/helpers for
// the target from wayu.toml. Generated files are never line-translated
// (their syntax is shell-specific: zsh globs, arrays, ...). Hand-written
// escape hatches (tools.<ext>, extra.<ext>) can't be translated either; they
// are reported so the user can port them.
migrate_shell_config :: proc(from_shell: ShellType, to_shell: ShellType) {
	from_ext := get_shell_extension(from_shell)
	to_ext := get_shell_extension(to_shell)
	to_name := get_shell_name(to_shell)

	toml_path := fmt.tprintf("%s/%s", wayu.config, WAYU_TOML)
	if !os.exists(toml_path) {
		print_error("Cross-shell migration rebuilds the %s files from wayu.toml, which does not exist", to_name)
		eprintfln_color("Import your legacy %s files first: %swayu --shell %s migrate%s", from_ext, get_primary(), from_ext, RESET)
		os.exit(EXIT_CONFIG)
	}

	if wayu.dry_run {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.println()
	}
	fmt.printfln("Migrating from %s to %s...", get_shell_name(from_shell), to_name)

	// Legacy definitions that never made it into wayu.toml would not follow
	// the user to the new shell.
	from_dialect := from_shell == .FISH ? ShellDialect.FISH : ShellDialect.POSIX
	for base in ([]string{"aliases", "constants", "path"}) {
		file := fmt.tprintf("%s/%s.%s", wayu.data, base, from_ext)
		if !os.exists(file) { continue }
		content, ok := safe_read_file(file)
		if !ok { continue }
		a := legacy_analyze(string(content), from_dialect)
		pending := len(a.entries) + len(a.issues)
		legacy_analysis_destroy(&a)
		delete(content)
		if pending > 0 {
			print_warning("%s.%s holds definitions that are not in wayu.toml; they will not carry over (import them with `wayu --shell %s migrate`)",
				base, from_ext, from_ext)
		}
	}

	// tools/extra are user shell code in the source dialect.
	for base in ([]string{"tools", "extra"}) {
		file := fmt.tprintf("%s/%s.%s", wayu.config, base, from_ext)
		if !os.exists(file) { continue }
		content, ok := safe_read_file(file)
		if !ok { continue }
		template := base == "tools" ? get_tools_template(from_shell) : get_extra_template(from_shell)
		if string(content) != template {
			print_warning("%s/%s.%s is hand-written %s code and is not translated; port it to %s.%s",
				wayu.config, base, from_ext, get_shell_name(from_shell), base, to_ext)
		}
		delete(content)
	}

	init_file := fmt.tprintf("%s/init.%s", wayu.data, to_ext)
	init_exists := os.exists(init_file)

	if wayu.dry_run {
		fmt.printfln("  Would set [shell] type = \"%s\" in wayu.toml", to_name)
		if !init_exists {
			fmt.printfln("  Would create %s", init_file)
		}
		fmt.printfln("  Would generate %s/core.%s (and its companions) from wayu.toml", wayu.data, to_ext)
		fmt.println()
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
		return
	}

	config_lock_acquire_or_exit()
	defer config_lock_release()

	res, _ := toml_kv_upsert("shell", "shell", "type", to_name)
	switch res {
	case .OK:
	case .MALFORMED:
		os.exit(EXIT_CONFIG)
	case .IO_ERROR, .NOT_FOUND:
		print_error("Could not update [shell] type in %s", toml_path)
		os.exit(EXIT_IOERR)
	}
	fmt.printfln("  ✓ wayu.toml [shell] type = \"%s\"", to_name)

	if !init_exists {
		template := get_init_template(to_shell)
		if write_file_atomic(init_file, transmute([]byte)template) != nil {
			print_error("Could not write %s", init_file)
			os.exit(EXIT_CANTCREAT)
		}
		fmt.printfln("  ✓ Created %s", init_file)
	} else {
		data, ok := safe_read_file(init_file)
		if ok {
			if !strings.contains(string(data), "Wayu Shell Initialization") {
				print_warning("%s is not a wayu orchestrator; left untouched (it must source core.%s)", init_file, to_ext)
			}
			delete(data)
		}
	}

	for base in ([]string{"tools", "extra"}) {
		file := fmt.tprintf("%s/%s.%s", wayu.config, base, to_ext)
		if os.exists(file) { continue }
		template := base == "tools" ? get_tools_template(to_shell) : get_extra_template(to_shell)
		init_config_file(file, template)
	}

	// Regenerate for the target shell (plus every other initialized shell).
	set_active_shell(to_shell)
	regenerate_init_core_silently()

	core_file := fmt.tprintf("%s/core.%s", wayu.data, to_ext)
	if !os.exists(core_file) {
		print_error("Failed to generate %s", core_file)
		os.exit(EXIT_IOERR)
	}
	fmt.printfln("  ✓ Generated %s from wayu.toml", core_file)

	fmt.printfln("\nMigration complete. Your %s files were left in place.", get_shell_name(from_shell))
	fmt.printfln("To use the new configuration:")
	#partial switch to_shell {
	case .BASH:
		fmt.printfln("  1. Add this line to your ~/.bashrc or ~/.bash_profile:")
	case .FISH:
		fmt.printfln("  1. Add this line to your ~/.config/fish/config.fish:")
	case:
		fmt.printfln("  1. Add this line to your ~/.zshrc:")
	}
	fmt.printfln("     source \"%s\"", init_file)
	fmt.printfln("  2. Restart your shell or source the RC file")
}

// One legacy file considered by `wayu migrate`.
@(private = "file")
LegacySource :: struct {
	base:     string, // "aliases" | "constants" | "path"
	path:     string, // heap
	label:    string, // heap: "<base>.<ext>"
	content:  string, // heap
	analysis: LegacyAnalysis,
}

// Pre-validate entries so a migration never stops half-way on a bad name.
// Returns the reason (heap) or "".
@(private = "file")
legacy_entry_validate :: proc(e: LegacyEntry) -> string {
	r: ValidationResult
	switch e.kind {
	case .Path:     r = validate_path(e.value)
	case .Alias:    r = validate_alias(e.name, e.value)
	case .Constant: r = validate_constant(e.name, e.value)
	}
	if len(r.warning) > 0 { delete(r.warning) }
	if r.valid { return "" }
	return r.error_message
}

// Migrate legacy shell configs to TOML format.
//
// All or nothing: every legacy file is analyzed first, and if any line can't
// be converted exactly (single-quoted/bare values are fine; functions,
// conditionals, command substitution, ... are not) the lines are listed and
// nothing is written. Once wayu.toml drives the shell (core.<ext>), legacy
// files are no longer sourced, so a partial import would drop them.
migrate_legacy_to_toml :: proc(dry_run: bool) {
	print_header("Legacy Config Migration", "🔄")
	fmt.println()

	dialect := wayu.shell == .FISH ? ShellDialect.FISH : ShellDialect.POSIX

	sources := make([dynamic]LegacySource)
	defer {
		for &s in sources {
			delete(s.path); delete(s.label); delete(s.content)
			legacy_analysis_destroy(&s.analysis)
		}
		delete(sources)
	}

	for base in ([]string{"aliases", "constants", "path"}) {
		path := fmt.aprintf("%s/%s.%s", wayu.data, base, wayu.shell_ext)
		if !os.exists(path) { delete(path); continue }
		data, ok := safe_read_file(path)
		if !ok {
			// Unreadable: never report "nothing to migrate" for it.
			// (safe_read_file already printed why.)
			delete(path)
			os.exit(EXIT_NOINPUT)
		}
		a := legacy_analyze(string(data), dialect)
		if len(a.entries) == 0 && len(a.issues) == 0 {
			// Missing, empty or wayu scaffolding only.
			legacy_analysis_destroy(&a)
			delete(data); delete(path)
			continue
		}
		append(&sources, LegacySource{
			base = base, path = path, content = string(data), analysis = a,
			label = fmt.aprintf("%s.%s", base, wayu.shell_ext),
		})
	}

	if len(sources) == 0 {
		print_success("No legacy shell config files found")
		fmt.println("Your configuration is already organized or empty.")
		return
	}

	// Entries the validators would reject are issues too.
	for &s in sources {
		for e in s.analysis.entries {
			if msg := legacy_entry_validate(e); len(msg) > 0 {
				append(&s.analysis.issues, LegacyIssue{first_line = e.line, last_line = e.line, reason = msg})
			}
		}
	}

	print_header("Found Legacy Files", "📋")
	total_issues := 0
	for s in sources {
		fmt.printfln("  • %s (%d entr%s)", s.label, len(s.analysis.entries), len(s.analysis.entries) == 1 ? "y" : "ies")
		total_issues += len(s.analysis.issues)
	}
	fmt.println()

	if total_issues > 0 {
		print_error("%d line(s) can't be migrated to wayu.toml exactly — nothing was changed", total_issues)
		fmt.eprintln()
		for s in sources {
			for is in s.analysis.issues { legacy_print_issue(s.label, s.content, is) }
		}
		fmt.eprintln()
		fmt.eprintfln("Move shell code you want to keep (functions, conditionals, ...) to %s/extra.%s,", wayu.config, wayu.shell_ext)
		fmt.eprintln("which wayu keeps sourcing, or rewrite it as plain `alias name='cmd'` /")
		eprintfln_color("`export NAME=value` lines, then re-run %swayu migrate%s.", get_primary(), RESET)
		os.exit(EXIT_DATAERR)
	}

	if dry_run {
		print_info("Dry-run mode: would import %d legacy file(s)", len(sources))
		for s in sources {
			fmt.println()
			fmt.printfln("  [%s]", s.label)
			for e in s.analysis.entries {
				switch e.kind {
				case .Path:     fmt.printfln("    path %s", e.value)
				case .Alias:    fmt.printfln("    %s = ...", e.name)
				case .Constant: fmt.printfln("    %s = ...", e.name)
				}
			}
		}
		fmt.println()
		fmt.printfln("Run %swayu migrate%s (without --dry-run) for actual migration", get_primary(), RESET)
		return
	}

	// ===== Real migration =====
	// toml_*_add keep wayu.toml canonical and back it up on each write.
	// Legacy files are renamed to .migrated so a re-run is a no-op and the
	// original content stays on disk for inspection.
	toml_path := fmt.aprintf("%s/%s", wayu.config, WAYU_TOML)
	defer delete(toml_path)
	if !os.exists(toml_path) {
		scaffold := "# wayu configuration (auto-generated by migrate)\n"
		if os.write_entire_file(toml_path, transmute([]byte)scaffold, SECRET_FILE_PERMS) != nil {
			print_error("Failed to create %s before migration", toml_path)
			os.exit(EXIT_CANTCREAT)
		}
	}

	migrated: [LegacyKind]int
	total_failed := 0
	kept_files := 0

	for s in sources {
		failed := 0
		for e in s.analysis.entries {
			ok_add := false
			err_msg := ""
			switch e.kind {
			case .Path:
				ok_add = toml_path_add(e.value)
			case .Alias:
				ok_add, err_msg = toml_alias_add(ConfigEntry{type = .ALIAS, name = e.name, value = e.value})
			case .Constant:
				ok_add, err_msg = toml_constant_add(ConfigEntry{type = .CONSTANT, name = e.name, value = e.value})
			}
			if ok_add {
				migrated[e.kind] += 1
				continue
			}
			failed += 1
			label := e.kind == .Path ? e.value : e.name
			if len(err_msg) > 0 {
				print_warning("Failed to migrate %s (line %d): %s", label, e.line, err_msg)
				delete(err_msg)
			} else {
				print_warning("Failed to migrate %s (line %d)", label, e.line)
			}
		}

		// Only archive when every entry made it into wayu.toml — otherwise
		// the legacy file is the only remaining copy of the failed entries.
		if failed > 0 {
			total_failed += failed
			kept_files += 1
			print_warning("%d entr%s from %s failed — left it in place (not archived)",
				failed, failed == 1 ? "y" : "ies", s.path)
			continue
		}

		archived := fmt.tprintf("%s.migrated", s.path)
		if rename_err := os.rename(s.path, archived); rename_err != nil {
			print_warning("Could not archive %s (error %v) — delete manually after reviewing", s.path, rename_err)
		} else {
			print_info("Archived %s → %s.migrated", s.path, s.label)
		}
	}

	fmt.println()
	if total_failed > 0 {
		print_error("Migration incomplete: %d paths, %d aliases, %d constants migrated; %d entr%s failed",
			migrated[.Path], migrated[.Alias], migrated[.Constant], total_failed, total_failed == 1 ? "y" : "ies")
		fmt.printfln("%d legacy file(s) were left in place. Fix the entries above and re-run %swayu migrate%s.",
			kept_files, get_primary(), RESET)
		os.exit(EXIT_DATAERR)
	}
	print_success("Migration complete: %d paths, %d aliases, %d constants", migrated[.Path], migrated[.Alias], migrated[.Constant])
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
	fmt.printf("  %s• Nothing is changed if any line can't be converted exactly; those lines are listed%s\n", get_muted(), RESET)
	fmt.printf("  %s• wayu.toml is backed up before every write (~/.config/wayu/backup/)%s\n", get_muted(), RESET)
	fmt.printf("  %s• Cross-shell mode sets [shell] type and regenerates the target's files from wayu.toml%s\n", get_muted(), RESET)
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

	// Read-modify-write of wayu.toml: hold the config lock like every other
	// writer, or a concurrent edit is lost (no-op under --dry-run).
	config_lock_acquire_or_exit()
	defer config_lock_release()

	content_bytes, ok := safe_read_file(toml_path)
	if !ok {
		// safe_read_file already printed why (one error per failure).
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

	// The sections below are dropped and re-emitted from what the one-line
	// parser read: a value it can't read (multi-line string, array, ...)
	// would silently disappear. Refuse and name the lines instead.
	unconvertible := migrate_schema_unconvertible(content)
	defer delete(unconvertible)
	if len(unconvertible) > 0 {
		print_error("%d line(s) in wayu.toml can't be migrated exactly — nothing was changed", len(unconvertible))
		src_lines := strings.split(content, "\n", context.temp_allocator)
		for n in unconvertible {
			fmt.eprintfln("  wayu.toml:%d: %s", n, strings.trim_space(src_lines[n - 1]))
		}
		fmt.eprintln("Rewrite them as single-line `key = \"value\"` entries and re-run `wayu migrate --schema`.")
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
		// Keep legacy declaration order: it is PATH precedence (first wins).
		body := render_keyed_body(paths[:])
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
			if migrate_section_header(trimmed) == "[paths]" { in_block = true; continue }
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
			if migrate_section_header(trimmed) == "[[paths]]" {
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
			if migrate_section_header(trimmed) == "[[aliases]]" {
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
			if migrate_section_header(trimmed) == "[aliases]" { in_block = true; continue }
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
			if migrate_section_header(trimmed) == "[[constants]]" {
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
			if migrate_section_header(trimmed) == section { in_block = true; continue }
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
	for line in lines {
		trimmed := strings.trim_space(line)
		if migrate_is_strip_header(trimmed) {
			in_strip = true
			continue
		}
		if strings.has_prefix(trimmed, "[") {
			in_strip = false
		}
		if in_strip { continue }
		fmt.sbprintln(&builder, line)
	}
	return strings.clone(strings.to_string(builder))
}

// `trimmed` header line without a trailing `# comment` (`[paths] # mine` ->
// `[paths]`), so the schema migration recognises the same headers the TOML
// reader does. Non-header lines are returned unchanged. Never allocates.
migrate_section_header :: proc(trimmed: string) -> string {
	if !strings.has_prefix(trimmed, "[") { return trimmed }
	if hash := strings.index_byte(trimmed, '#'); hash >= 0 {
		return strings.trim_space(trimmed[:hash])
	}
	return trimmed
}

@(private = "file")
migrate_is_strip_header :: proc(trimmed: string) -> bool {
	h := migrate_section_header(trimmed)
	for s in MIGRATE_STRIP_HEADERS {
		if h == s { return true }
	}
	return false
}

// 1-based numbers of the lines inside the sections `migrate --schema`
// rewrites that its one-line parser can't read exactly: multi-line strings
// (and their continuation lines), arrays, inline tables, malformed lines.
// Those sections are dropped and re-emitted from the parsed entries, so such
// a line would vanish (or an alias would lose its command).
migrate_schema_unconvertible :: proc(content: string) -> [dynamic]int {
	out := make([dynamic]int)
	lines := strings.split(content, "\n")
	defer delete(lines)

	in_section := false
	for line, i in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "[") && strings.has_suffix(migrate_section_header(trimmed), "]") {
			in_section = migrate_is_strip_header(trimmed)
			continue
		}
		if !in_section || len(trimmed) == 0 || trimmed[0] == '#' { continue }
		k, v, ok := migrate_parse_toml_kv(trimmed)
		if ok {
			delete(k); delete(v)
			continue
		}
		append(&out, i + 1)
	}
	return out
}
