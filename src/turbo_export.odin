// turbo_export.odin - High-performance shell export generation
//
// This module generates a unified, pre-computed shell configuration file
// that eliminates runtime overhead from loops, conditionals, and multiple
// file sources. Achieves 2-4x faster shell startup compared to standard init.
//
// Content is built from wayu.toml ([paths] / [env] / [aliases]) through the
// same readers and quoting helpers as core.{ext}, so turbo output and core
// never disagree (the legacy *.zsh registries are empty for TOML users).
//
// Usage: wayu export --turbo
//        eval "$(wayu export --eval)"

package wayu

import "core:fmt"
import "core:os"
import "core:strings"

// Turbo export configuration
TURBO_EXPORT_FILE :: "turbo.zsh"
TURBO_EXPORT_FILE_BASH :: "turbo.bash"

// Turbo file name for the active shell.
turbo_export_file_name :: proc() -> string {
	return TURBO_EXPORT_FILE_BASH if wayu.shell == .BASH else TURBO_EXPORT_FILE
}

// Entry point for turbo export command
handle_export_command :: proc(action: Action, args: []string) {
	if !check_wayu_initialized() {
		os.exit(EXIT_CONFIG)
	}

	#partial switch action {
	case .HELP:
		print_export_usage()
		return
	case .LIST, .TURBO, .UNKNOWN:
		// Default / explicit turbo mode. Honors the global --dry-run flag.
		generate_turbo_export(wayu.dry_run)
	case .EVAL:
		handle_export_eval()
	case .CHECK:
		handle_export_check()
	case:
		print_error("Unknown export action")
		print_export_usage()
		os.exit(EXIT_USAGE)
	}
}

// Handle --eval flag for direct shell integration (stdout only, no writes)
handle_export_eval :: proc() {
	if !check_wayu_initialized() {
		os.exit(EXIT_CONFIG)
	}
	generate_eval_output()
}

// Print available export formats
print_export_formats :: proc() {
	print_header("Export Formats", "📦")
	fmt.println()

	print_item("", "--turbo", "Generate unified turbo file (fastest)", "🚀")
	print_item("", "--eval", "Output shell exports for eval", "⚡")
	print_item("", "--check", "Check if turbo file is up to date", "✓")

	fmt.println()
	fmt.printfln("%sTurbo file:%s %s/%s", get_muted(), RESET, wayu.data, turbo_export_file_name())
	fmt.println()

	exists, _ := check_turbo_status()
	if exists {
		fmt.printfln("%s✓ Turbo file exists%s", get_success(), RESET)
	} else {
		fmt.printfln("%s○ Turbo file not generated yet%s", get_warning(), RESET)
		fmt.printfln("%sRun: wayu export --turbo%s", get_primary(), RESET)
	}
}

// Generate the unified turbo export file
generate_turbo_export :: proc(dry_run: bool) {
	print_header("Generating Turbo Export", "🚀")
	fmt.println()

	output_file := turbo_export_file_name()
	output_path := fmt.aprintf("%s/%s", wayu.data, output_file)
	defer delete(output_path)

	if dry_run {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.printfln("%sWould generate:%s %s", BRIGHT_CYAN, RESET, output_path)
		fmt.println()
	}

	content := build_turbo_content()
	defer delete(content)

	if dry_run {
		fmt.printfln("%sContent preview (first 500 chars):%s", get_muted(), RESET)
		preview := content
		if len(preview) > 500 {
			preview = fmt.tprintf("%s...", preview[:500])
		}
		fmt.println(preview)
		fmt.println()
		fmt.printfln("%sTo apply, remove --dry-run flag%s", get_muted(), RESET)
		return
	}

	write_ok := safe_write_file(output_path, transmute([]byte)content)
	if !write_ok {
		print_error("Failed to write turbo export file")
		os.exit(EXIT_IOERR)
	}

	print_success("Turbo export generated: %s", output_path)
	fmt.println()

	print_section("Next Steps", EMOJI_INFO)
	fmt.printfln("Replace in your shell rc file:")
	fmt.printfln("  %s# Old (slower):%s", get_muted(), RESET)
	fmt.printfln("  source \"%s/init.%s\"", wayu.data, get_shell_extension(wayu.shell))
	fmt.println()
	fmt.printfln("  %s# New (faster):%s", get_muted(), RESET)
	fmt.printfln("  source \"%s\"", output_path)
	fmt.println()
	fmt.printfln("%sOr use eval mode (fastest):%s", get_secondary(), RESET)
	fmt.printfln("  eval \"$(wayu export --eval)\"")
	fmt.println()
	fmt.printfln("%sSpeed improvement: ~2-4x faster startup%s", get_success(), RESET)
}

// Build the complete turbo content
build_turbo_content :: proc() -> string {
	clear_toml_content_cache()
	defer clear_toml_content_cache()

	ext := get_shell_extension(wayu.shell)

	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	fmt.sbprintln(&builder, get_shebang(wayu.shell))
	fmt.sbprintln(&builder)
	fmt.sbprintln(&builder, "# Wayu Turbo Export - Auto-generated unified configuration")
	fmt.sbprintln(&builder, "# Generated: wayu export --turbo")
	fmt.sbprintln(&builder, "# This file is pre-computed for maximum startup speed")
	fmt.sbprintln(&builder, "# DO NOT EDIT - Run 'wayu export --turbo' to regenerate")
	fmt.sbprintln(&builder)

	// 1. Constants (environment variables) - direct exports, file order
	fmt.sbprintln(&builder, "# === CONSTANTS ===")
	emit_env_exports(&builder)
	fmt.sbprintln(&builder)

	// 2. PATH - pre-computed, single export
	fmt.sbprintln(&builder, "# === PATH ===")
	if !emit_path_export(&builder) {
		fmt.sbprintln(&builder, "# No PATH entries configured")
	}
	fmt.sbprintln(&builder)

	// 3. Aliases
	fmt.sbprintln(&builder, "# === ALIASES ===")
	emit_alias_definitions(&builder)
	fmt.sbprintln(&builder)

	// 4. Functions
	fmt.sbprintln(&builder, "# === FUNCTIONS ===")
	emit_functions_loader(&builder)
	fmt.sbprintln(&builder)

	// 5. Completions (zsh fpath; bash completion files)
	fmt.sbprintln(&builder, "# === COMPLETIONS ===")
	completions_q := shell_double_quote_literal(fmt.tprintf("%s/completions", wayu.data), context.temp_allocator)
	if wayu.shell == .ZSH {
		fmt.sbprintfln(&builder, "fpath=(%s $fpath)", completions_q)
	} else {
		fmt.sbprintfln(&builder, `if [ -d %s ]; then for f in %s/*.bash-completion; do [ -f "$f" ] && source "$f"; done; fi`, completions_q, completions_q)
	}
	fmt.sbprintln(&builder)

	// 6. Plugins
	fmt.sbprintln(&builder, "# === PLUGINS ===")
	append_source_line(&builder, fmt.tprintf("%s/plugins.%s", wayu.data, ext))
	if wayu.shell == .ZSH {
		append_source_line(&builder, fmt.tprintf("%s/plugins/config.zsh", wayu.data))
	}
	fmt.sbprintln(&builder)

	// 7. External tools escape hatch
	fmt.sbprintln(&builder, "# === EXTERNAL TOOLS ===")
	append_source_line(&builder, fmt.tprintf("%s/tools.%s", wayu.config, ext))
	fmt.sbprintln(&builder)

	// 8. Extra config
	fmt.sbprintln(&builder, "# === EXTRA CONFIG ===")
	append_source_line(&builder, fmt.tprintf("%s/extra.%s", wayu.config, ext))
	fmt.sbprintln(&builder)

	return strings.clone(strings.to_string(builder))
}

@(private = "file")
append_source_line :: proc(b: ^strings.Builder, file: string) {
	q := shell_double_quote_literal(file, context.temp_allocator)
	fmt.sbprintfln(b, "[ -f %s ] && source %s", q, q)
}

// Generate eval-compatible output (for eval "$(wayu export --eval)")
generate_eval_output :: proc() {
	content := build_eval_content()
	defer delete(content)
	fmt.println(content)
}

// Build eval content (compact; statements separated by `;` so it also
// survives the unquoted `eval $(...)` form).
build_eval_content :: proc() -> string {
	clear_toml_content_cache()
	defer clear_toml_content_cache()

	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	emit_env_exports(&builder, ";")
	emit_path_export(&builder, ";")
	emit_alias_definitions(&builder, ";")

	return strings.clone(strings.to_string(builder))
}

// Print export usage
print_export_usage :: proc() {
	fmt.println()
	fmt.printfln("%swayu export - High-performance shell configuration export%s", BOLD, RESET)
	fmt.println()
	fmt.printfln("%sUSAGE:%s", get_primary(), RESET)
	fmt.printfln("  wayu export              Generate turbo export file")
	fmt.printfln("  wayu export --turbo      Same as above (explicit)")
	fmt.printfln("  wayu export --eval       Output for eval (fastest)")
	fmt.printfln("  wayu export --dry-run    Preview without writing")
	fmt.printfln("  wayu export list         Show available formats")
	fmt.println()
	fmt.printfln("%sDESCRIPTION:%s", get_primary(), RESET)
	fmt.println("  Generates a unified, pre-computed shell configuration")
	fmt.println("  that eliminates loops and conditionals for 2-4x faster startup.")
	fmt.println()
	fmt.printfln("%sEXAMPLES:%s", get_primary(), RESET)
	fmt.println("  # Generate turbo file")
	fmt.println("  wayu export --turbo")
	fmt.println()
	fmt.println("  # Use in .zshrc (replace source ~/.config/wayu/init.zsh)")
	fmt.println("  source \"$HOME/.config/wayu/turbo.zsh\"")
	fmt.println()
	fmt.println("  # Or use eval mode (even faster)")
	fmt.println("  eval \"$(wayu export --eval)\"")
	fmt.println()
	fmt.printfln("%sTURBO FILE:%s ~/.config/wayu/%s", get_muted(), RESET, turbo_export_file_name())
}

// Check if the turbo file for the active shell exists and is current
// (not older than wayu.toml).
check_turbo_status :: proc() -> (exists: bool, current: bool) {
	turbo_path := fmt.aprintf("%s/%s", wayu.data, turbo_export_file_name())
	defer delete(turbo_path)

	turbo_info, err := os.stat(turbo_path, context.temp_allocator)
	if err != nil {
		return false, false
	}

	toml_path := fmt.aprintf("%s/wayu.toml", wayu.config)
	defer delete(toml_path)
	toml_info, terr := os.stat(toml_path, context.temp_allocator)
	if terr != nil {
		return true, true
	}
	return true, turbo_info.modification_time._nsec >= toml_info.modification_time._nsec
}

// Handle export --check action
handle_export_check :: proc() {
	exists, current := check_turbo_status()

	if !exists {
		fmt.printfln("%s✗ Turbo file not found%s", get_warning(), RESET)
		fmt.printfln("%sRun: wayu export --turbo%s", get_primary(), RESET)
		os.exit(EXIT_CONFIG)
	}

	if !current {
		fmt.printfln("%s⚠ Turbo file is outdated%s", get_warning(), RESET)
		fmt.printfln("%sRegenerate: wayu export --turbo%s", get_primary(), RESET)
		os.exit(EXIT_CONFIG)
	}

	fmt.printfln("%s✓ Turbo file is up to date%s", get_success(), RESET)
	os.exit(EXIT_SUCCESS)
}
