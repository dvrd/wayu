// turbo_export.odin - `wayu export`
//
// Since OKAMI-284 the regular generated init is itself a single precomputed
// file (core.<ext>, sourced by init.<ext>) with every feature, so turbo is
// thin: turbo.<ext> is written with exactly core.<ext>'s content (and kept
// in step whenever core is regenerated). It stays for rc files that already
// source it; init.<ext> is just as fast.
//
// Usage: wayu export [--turbo]          (writes turbo.<ext>)
//        eval "$(wayu export --eval)"   (env + PATH + aliases only)
//
// Scope of --eval: [env], [paths], [aliases] only (it is for eval contexts);
// no functions, completions, plugins, [tools], prompt or live PATH sync.
// zsh/bash only: fish is refused.

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
	// help/list/usage errors need no config (OKAMI-237): check init after.
	#partial switch action {
	case .HELP:
		print_export_usage()
		return
	case .LIST:
		print_export_formats()
		return
	case .UNKNOWN:
		print_error_simple("Unknown export mode")
		print_export_usage()
		os.exit(EXIT_USAGE)
	}

	if !check_wayu_initialized() {
		os.exit(EXIT_CONFIG)
	}

	// Turbo/eval emit sh syntax (`if [ ... ]; then`, `export`): never hand
	// that to fish (OKAMI-233).
	if wayu.shell == .FISH && (action == .TURBO || action == .EVAL) {
		print_error_simple("wayu export does not support fish; source init.fish instead (wayu build)")
		os.exit(EXIT_USAGE)
	}

	#partial switch action {
	case .TURBO:
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

	print_item("", "--turbo", "Write turbo file (same as core.<ext>)", "🚀")
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

	content := build_turbo_content(mask_secrets = dry_run)
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

	// turbo.<ext> runs the live PATH sync like core: keep its file current.
	sync_file := write_path_sync_file()
	delete(sync_file)
	if !write_turbo_file(output_path, content) {
		print_error("Failed to write turbo export file")
		os.exit(EXIT_IOERR)
	}
	flush_zcompile_batch()

	print_success("Turbo export generated: %s", output_path)
	fmt.println()
	fmt.printfln("turbo.%s has the same content as core.%s (what init.%s loads): every feature,", get_shell_extension(wayu.shell), get_shell_extension(wayu.shell), get_shell_extension(wayu.shell))
	fmt.println("same speed. wayu keeps it up to date; sourcing init is equivalent:")
	fmt.printfln("  source \"%s/init.%s\"", wayu.data, get_shell_extension(wayu.shell))
	fmt.println()
	fmt.printfln("%sEval mode (env, PATH and aliases only):%s", get_secondary(), RESET)
	fmt.printfln("  eval \"$(wayu export --eval)\"")
}

// Turbo content: since OKAMI-284 the same generated output as core.<ext>
// (every feature, already a single precomputed file), so sourcing
// turbo.<ext> and init.<ext> behave the same. `mask_secrets` is set for the
// --dry-run preview (OKAMI-208). Caller owns the result.
build_turbo_content :: proc(mask_secrets := false) -> string {
	clear_toml_content_cache()
	defer clear_toml_content_cache()
	return build_core_content(mask = mask_secrets)
}

// Write turbo.<ext> (always rewritten, so `export --check` sees a fresh
// mtime), owner-only (embeds [env] values, OKAMI-206), zcompiled for zsh.
write_turbo_file :: proc(path, content: string) -> bool {
	if write_file_atomic(path, transmute([]byte)content) != nil {
		return false
	}
	restrict_file_mode(path)
	zwc := fmt.tprintf("%s.zwc", path)
	if os.exists(zwc) { os.remove(zwc) }
	zcompile_file(path)
	return true
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
	emit_secrets_loader(&builder, wayu.shell, ";")
	emit_path_eval(&builder, ";")
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
	fmt.printfln("  wayu export --eval       Print env/PATH/aliases for eval (no writes)")
	fmt.printfln("  wayu export --check      Exit 0 if the turbo file is current, 78 if not")
	fmt.printfln("  wayu export --dry-run    Preview without writing")
	fmt.printfln("  wayu export list         Show available formats")
	fmt.println()
	fmt.printfln("%sDESCRIPTION:%s", get_primary(), RESET)
	fmt.println("  Writes turbo.<ext>: the same single precomputed file init.<ext> loads")
	fmt.println("  (core.<ext>), kept up to date by wayu. Sourcing init.<ext> is just")
	fmt.println("  as fast; turbo stays for rc files that already use it. zsh/bash only.")
	fmt.println("  --eval prints only constants, PATH entries and aliases (for eval contexts).")
	fmt.println()
	fmt.printfln("%sEXAMPLES:%s", get_primary(), RESET)
	fmt.println("  # Generate turbo file")
	fmt.println("  wayu export --turbo")
	fmt.println()
	fmt.println("  # Use in .zshrc (equivalent to sourcing init.zsh)")
	fmt.println("  source \"${WAYU_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/wayu}/turbo.zsh\"")
	fmt.println()
	fmt.println("  # Or eval mode (env, PATH and aliases only)")
	fmt.println("  eval \"$(wayu export --eval)\"")
	fmt.println()
	fmt.printfln("%sTURBO FILE:%s %s/%s", get_muted(), RESET, wayu.data, turbo_export_file_name())
}

// Check if the turbo file for the active shell exists and is current
// (not older than wayu.toml or entries.json).
check_turbo_status :: proc() -> (exists: bool, current: bool) {
	turbo_path := fmt.aprintf("%s/%s", wayu.data, turbo_export_file_name())
	defer delete(turbo_path)

	turbo_info, err := os.stat(turbo_path, context.temp_allocator)
	if err != nil {
		return false, false
	}

	current = true
	for src in ([]string{fmt.tprintf("%s/wayu.toml", wayu.config), entries_file_path()}) {
		info, serr := os.stat(src, context.temp_allocator)
		if serr != nil { continue }
		if turbo_info.modification_time._nsec < info.modification_time._nsec { current = false }
	}
	return true, current
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
