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

handle_migrate_command :: proc(args: []string) {
	// Check for --from flag (shell migration vs legacy config migration)
	has_from := false

	for arg in args {
		if arg == "--from" {
			has_from = true
			break
		}
	}

	// Legacy config migration: `wayu migrate` (no flags) or `wayu migrate --dry-run`.
	// The shell→shell path requires --from, so anything without --from that isn't
	// "help" is treated as a legacy config migration.
	if !has_from {
		// Allow `wayu migrate help` / `-h` / `--help` to fall through to the
		// help printer rather than running a migration.
		for arg in args {
			if arg == "help" || arg == "-h" || arg == "--help" {
				print_migrate_help()
				return
			}
		}
		migrate_legacy_to_toml(DRY_RUN)
		return
	}

	if len(args) == 0 {
		print_migrate_help()
		return
	}

	from_shell := ShellType.UNKNOWN
	to_shell := ShellType.UNKNOWN

	// Parse migration arguments
	i := 0
	for i < len(args) {
		arg := args[i]
		if arg == "--from" && i + 1 < len(args) {
			from_shell = parse_shell_type(args[i + 1])
			i += 1
		} else if arg == "--to" && i + 1 < len(args) {
			to_shell = parse_shell_type(args[i + 1])
			i += 1
		} else if arg == "help" || arg == "-h" || arg == "--help" {
			print_migrate_help()
			return
		} else {
			fmt.eprintfln("Unknown migrate option: %s", arg)
			print_migrate_help()
			os.exit(EXIT_USAGE)
		}
		i += 1
	}

	// Validate arguments
	if from_shell == .UNKNOWN {
		fmt.eprintfln("Error: --from shell must be specified (bash, zsh, or fish)")
		print_migrate_help()
		os.exit(EXIT_USAGE)
	}

	if to_shell == .UNKNOWN {
		fmt.eprintfln("Error: --to shell must be specified (bash, zsh, or fish)")
		print_migrate_help()
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

	fmt.printfln("Migrating from %s to %s...", get_shell_name(from_shell), get_shell_name(to_shell))

	config_types := []string{"path", "aliases", "constants", "init", "tools"}
	migrated_count := 0

	for config_type in config_types {
		from_file := fmt.aprintf("%s/%s.%s", WAYU_CONFIG, config_type, from_ext)
		to_file := fmt.aprintf("%s/%s.%s", WAYU_CONFIG, config_type, to_ext)
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
			continue
		}
		defer delete(data)

		content := string(data)

		// Convert shell-specific content
		migrated_content := convert_shell_content(content, from_shell, to_shell, config_type)
		defer delete(migrated_content)

		// Write to target file
		write_err := os.write_entire_file(to_file, transmute([]byte)migrated_content)
		if write_err != nil {
			fmt.eprintfln("  Error: Failed to write %s", to_file)
			continue
		}

		fmt.printfln("  ✓ Migrated %s.%s → %s.%s", config_type, from_ext, config_type, to_ext)
		migrated_count += 1
	}

	if migrated_count > 0 {
		fmt.printfln("\nMigration completed! Migrated %d configuration file(s).", migrated_count)
		fmt.printfln("To use the new configuration:")
		#partial switch to_shell {
		case .BASH:
			fmt.printfln("  1. Add this line to your ~/.bashrc or ~/.bash_profile:")
			fmt.printfln("     source \"%s/init.bash\"", WAYU_CONFIG)
		case .FISH:
			fmt.printfln("  1. Add this line to your ~/.config/fish/config.fish:")
			fmt.printfln("     source \"%s/init.fish\"", WAYU_CONFIG)
		case:
			fmt.printfln("  1. Add this line to your ~/.zshrc:")
			fmt.printfln("     source \"%s/init.zsh\"", WAYU_CONFIG)
		}
		fmt.printfln("  2. Restart your shell or source the RC file")
	} else {
		fmt.printfln("\nNo files were migrated. Check that source files exist and target files don't already exist.")
	}
}

convert_shell_content :: proc(content: string, from_shell: ShellType, to_shell: ShellType, config_type: string) -> string {
	// For now, simply convert shebang and basic shell references
	// More sophisticated conversion can be added later

	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	lines := strings.split_lines(content)
	defer delete(lines)

	for line, i in lines {
		converted_line := line

		// Convert shebang
		if strings.has_prefix(line, "#!/usr/bin/env") {
			#partial switch to_shell {
			case .BASH: converted_line = "#!/usr/bin/env bash"
			case .FISH: converted_line = "#!/usr/bin/env fish"
			case: converted_line = "#!/usr/bin/env zsh"
			}
		}

		// Convert alias + export syntax between POSIX shells and fish.
		// Fish:  alias NAME 'CMD'       ↔  bash/zsh: alias NAME="CMD"
		// Fish:  set -gx NAME "VAL"     ↔  bash/zsh: export NAME="VAL"
		// We work line-by-line with the existing parsers, which already
		// handle both dialects (see config_specs.odin).
		if to_shell == .FISH && (from_shell == .BASH || from_shell == .ZSH) {
			if entry, ok := parse_alias_line(line); ok {
				converted_line = fmt.aprintf("alias %s '%s'", entry.name, entry.value)
				cleanup_entry(&entry)
			} else if entry, ok := parse_constant_line(line); ok {
				converted_line = fmt.aprintf(`set -gx %s "%s"`, entry.name, entry.value)
				cleanup_entry(&entry)
			}
		} else if from_shell == .FISH && (to_shell == .BASH || to_shell == .ZSH) {
			if entry, ok := parse_alias_line(line); ok {
				converted_line = fmt.aprintf(`alias %s="%s"`, entry.name, entry.value)
				cleanup_entry(&entry)
			} else if entry, ok := parse_constant_line(line); ok {
				converted_line = fmt.aprintf(`export %s="%s"`, entry.name, entry.value)
				cleanup_entry(&entry)
			}
		}

		// Convert shell comments
		if strings.contains(line, "(ZSH)") && to_shell == .BASH {
			// Basic replacement - will improve later
			converted_line = line  // Keep original for now
		} else if strings.contains(line, "(Bash)") && to_shell == .ZSH {
			converted_line = line  // Keep original for now
		}

		// Special handling for path.* files - convert deduplication method
		if config_type == "path" {
			if from_shell == .ZSH && to_shell == .BASH {
				// Convert ZSH awk one-liner to Bash array method
				if strings.contains(line, "export PATH=$(echo \"$PATH\" | awk") {
					converted_line = "remove_path_duplicates"
				}
			} else if from_shell == .BASH && to_shell == .ZSH {
				// Convert Bash array method to ZSH awk one-liner
				if strings.trim_space(line) == "remove_path_duplicates" {
					converted_line = "# Remove duplicates from PATH (ZSH-optimized method)\nexport PATH=$(echo \"$PATH\" | awk -v RS=':' -v ORS=':' '!seen[$0]++' | sed 's/:$//')"
				}
			}
		}

		strings.write_string(&builder, converted_line)
		if i < len(lines) - 1 {
			strings.write_string(&builder, "\n")
		}
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
		config_file := fmt.aprintf("%s/%s.%s", WAYU_CONFIG, file, SHELL_EXT)
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
		fmt.printfln("  • %s.%s", file, SHELL_EXT)
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
			aliases_file := fmt.aprintf("%s/aliases.%s", WAYU_CONFIG, SHELL_EXT)
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
	toml_path := fmt.aprintf("%s/%s", WAYU_CONFIG, WAYU_TOML)
	defer delete(toml_path)
	if !os.exists(toml_path) {
		// Seed a minimal scaffold so toml_*_add has a file to append to.
		scaffold := "# wayu configuration (auto-generated by migrate)\n"
		if os.write_entire_file(toml_path, transmute([]byte)scaffold) != nil {
			print_error("Failed to create %s before migration", toml_path)
			return
		}
	}

	migrated_paths     := 0
	migrated_aliases   := 0
	migrated_constants := 0

	for file in found_files {
		legacy_file := fmt.aprintf("%s/%s.%s", WAYU_CONFIG, file, SHELL_EXT)
		defer delete(legacy_file)

		content, ok := safe_read_file(legacy_file)
		if !ok {
			print_warning("Could not read %s — skipping", legacy_file)
			continue
		}

		lines := strings.split(string(content), "\n")

		switch file {
		case "path":
			for line in lines {
				entry, parsed := parse_path_line(line)
				if !parsed { continue }
				if toml_path_add(entry.name) {
					migrated_paths += 1
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
				} else if len(err_msg) > 0 {
					print_warning("Skipped alias %s: %s", entry.name, err_msg)
					delete(err_msg)
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
				} else if len(err_msg) > 0 {
					print_warning("Skipped constant %s: %s", entry.name, err_msg)
					delete(err_msg)
				}
				cleanup_entry(&entry)
			}
		}

		delete(lines)
		delete(content)

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
	print_success("Migration complete: %d paths, %d aliases, %d constants", migrated_paths, migrated_aliases, migrated_constants)
	fmt.println()
	fmt.printfln("Review the result with %swayu toml show%s", get_primary(), RESET)
	fmt.printfln("Legacy files preserved as *.%s.migrated (safe to delete once verified)", SHELL_EXT)
}

print_migrate_help :: proc() {
	// Title
	fmt.printf("\n%s%swayu migrate - Migrate configuration%s\n\n", BOLD, get_primary(), RESET)

	// Usage section
	fmt.printf("%s%sUSAGE:%s\n", BOLD, get_secondary(), RESET)
	fmt.println("  wayu migrate                         # Legacy file layout → wayu.toml")
	fmt.println("  wayu migrate --dry-run               # Preview legacy → TOML conversion")
	fmt.println("  wayu migrate --from <shell> --to <shell>   # Cross-shell migration")

	// Options section
	fmt.printf("\n%s%sOPTIONS:%s\n", BOLD, get_secondary(), RESET)
	fmt.println("  --dry-run, -n        Preview without modifying files (legacy mode only)")
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
	fmt.printf("  %s• Legacy migration archives source files as *.%s.migrated%s\n", get_muted(), SHELL_EXT, RESET)
	fmt.printf("  %s• wayu.toml is backed up before every write (timestamped in ~/.config/wayu)%s\n", get_muted(), RESET)
	fmt.printf("  %s• Cross-shell mode creates new shell-specific config files%s\n", get_muted(), RESET)
	fmt.printf("  %s• You may need to update your shell RC file after cross-shell migration%s\n", get_muted(), RESET)
	fmt.println()
}

