// build_output.odin - Optimized eval output + supporting `append_*` helpers
//
// Extracted from main.odin (2026-04-24) per code review L1. Implements the
// `wayu build export-optimized` code path: generate all optimized init files
// and print the `source ...` command for shell integration. Combines the
// following optimization techniques:
//
//   1. zcompile bytecode compilation (2-3x faster loading)
//   2. zsh-defer deferred execution (prompt appears instantly)
//   3. evalcache (cache eval output, regenerate if binary changes)
//   4. batch exports (typeset -gx, single line)
//   5. optimized compinit (24h cache check)
//   6. split files (core/lazy/login)
//
// The `handle_build_command` dispatcher stays in main.odin; this file owns
// the output-rendering pipeline.

package wayu

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"

// Generate optimized eval output - implements ALL optimization techniques:
// 1. zcompile bytecode compilation (2-3x faster loading)
// 2. zsh-defer deferred execution (prompt appears instantly)
// 3. evalcache (cache eval output, regenerate if binary changes)
// 4. batch exports (typeset -gx, single line)
// 5. optimized compinit (24h cache check)
// 6. split files (core/lazy/login)
generate_eval_output_optimized :: proc() {
	// Generate all optimized init files
	generate_optimized_init_all()
	
	// Output source command for core (essential only, < 10ms)
	core_file := fmt.aprintf("%s/init-core.zsh", WAYU_CONFIG)
	defer delete(core_file)
	
	fmt.printfln(`source "%s"`, core_file)
}

// Append optimized PATH export - ordered: personal > homebrew > system
// Generates absolute PATH without depending on existing $PATH (prevents duplication on re-source)
append_path_optimized :: proc(builder: ^strings.Builder, paths: []BuildPathEntry, level: OptimizationLevel) {
	// Validate and categorize paths
	personal_paths := make([dynamic]string, context.temp_allocator)
	homebrew_paths := make([dynamic]string, context.temp_allocator)
	
	for path in paths {
		expanded := path.expanded
		if len(expanded) == 0 { continue }
		
		// Skip system paths - they get added explicitly at the end
		if strings.has_prefix(expanded, "/usr/bin") || 
		   strings.has_prefix(expanded, "/bin") || 
		   strings.has_prefix(expanded, "/usr/sbin") || 
		   strings.has_prefix(expanded, "/sbin") ||
		   strings.has_prefix(expanded, "/usr/local/bin") ||
		   strings.has_prefix(expanded, "/usr/local/sbin") ||
		   strings.has_prefix(expanded, "/Library/") {
			continue
		}
		
		// Categorize by path type
		if strings.has_prefix(expanded, "/opt/homebrew/") || strings.has_prefix(expanded, "/usr/local/Cellar/") {
			append(&homebrew_paths, expanded)
		} else {
			// Personal paths (home directory, dev projects, etc.)
			append(&personal_paths, expanded)
		}
	}
	
	// Build complete PATH from scratch - no $PATH dependency
	fmt.sbprint(builder, "export PATH=\"")
	
	first := true
	
	// 1. Personal paths first (highest priority)
	for p in personal_paths {
		if !first { fmt.sbprint(builder, ":") }
		fmt.sbprint(builder, p)
		first = false
	}
	
	// 2. Homebrew paths second
	for p in homebrew_paths {
		if !first { fmt.sbprint(builder, ":") }
		fmt.sbprint(builder, p)
		first = false
	}
	
	// 3. System paths (absolute, not from $PATH)
	system_paths := []string{"/usr/local/bin", "/usr/local/sbin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"}
	for p in system_paths {
		if !first { fmt.sbprint(builder, ":") }
		fmt.sbprint(builder, p)
		first = false
	}
	
	fmt.sbprintln(builder, "\"")
	fmt.sbprintln(builder)
	
	// Add deduplication guard (for safety if user has other PATH modifications)
	fmt.sbprintln(builder, "# Ensure PATH deduplication")
	fmt.sbprintln(builder, "typeset -U PATH 2>/dev/null || true")
	fmt.sbprintln(builder)
}

// Append constants as direct exports
append_constants_optimized :: proc(builder: ^strings.Builder, constants: []BuildConstantEntry) {
	for c in constants {
		fmt.sbprintf(builder, "export %s=\"%s\"\n", c.name, c.value)
	}
	if len(constants) > 0 {
		fmt.sbprintln(builder)
	}
}

// Append aliases as direct definitions
append_aliases_optimized :: proc(builder: ^strings.Builder, aliases: []BuildAliasEntry) {
	for a in aliases {
		fmt.sbprintf(builder, "alias %s=\"%s\"\n", a.name, a.command)
	}
	if len(aliases) > 0 {
		fmt.sbprintln(builder)
	}
}

// Validate and sort paths using optimal strategy
validate_and_sort_paths :: proc(paths: []BuildPathEntry, level: OptimizationLevel) -> []BuildPathEntry {
	// Use the adaptive optimizer based on level
	switch level {
	case .SCALAR:
		return validate_paths_scalar(paths)
	case .SIMD:
		return validate_paths_simd(paths)
	case .THREADED:
		return validate_paths_threaded(paths)
	case .GPU:
		return validate_paths_gpu(paths)
	}
	return paths
}

// Append Starship init inline from cache (only the essential part for fast prompt)
append_starship_inline :: proc(builder: ^strings.Builder) {
	home := os.get_env("HOME", context.temp_allocator)
	cache_file := fmt.aprintf("%s/.cache/wayu/starship.zsh", home)
	defer delete(cache_file)
	
	if os.exists(cache_file) {
		content, ok := safe_read_file(cache_file)
		if ok && len(content) > 0 {
			// Inline the full starship init (it's needed for the prompt)
			fmt.sbprintln(builder, string(content))
		}
	} else {
		// Fallback: source starship the old way if cache doesn't exist
		fmt.sbprintln(builder, `eval "$(starship init zsh)"`)
	}
}

// Print build command help
print_build_help :: proc() {
	fmt.println()
	fmt.printfln("%swayu build - Compile wayu.toml to optimized shell config%s", BOLD, RESET)
	fmt.println()
	fmt.printfln("%sUSAGE:%s", get_primary(), RESET)
	fmt.printfln("  wayu build              Standard optimized build")
	fmt.printfln("  wayu build turbo        Maximum optimization (turbo.zsh)")
	fmt.printfln("  wayu build eval         Generate eval-able output (fastest)")
	fmt.printfln("  wayu build profile      Measure shell startup time (5-iter mean)")
	fmt.printfln("  wayu build help         Show this help")
	fmt.println()
	fmt.printfln("%sDESCRIPTION:%s", get_primary(), RESET)
	fmt.println("  Compiles wayu.toml into optimized shell configuration.")
	fmt.println("  Uses adaptive optimization:")
	fmt.println("    • Scalar:     < 100 items (simple, no overhead)")
	fmt.println("    • SIMD:       100-1000 items (vectorized)")
	fmt.println("    • Threaded:   1000-10000 items (parallel)")
	fmt.println("    • GPU:        > 10000 items (massive parallel)")
	fmt.println()
	fmt.printfln("%sEXAMPLES:%s", get_primary(), RESET)
	fmt.println("  wayu build              # Build init.zsh from wayu.toml")
	fmt.println("  wayu build turbo        # Build turbo.zsh")
	fmt.println("  wayu build eval         # Fastest: eval in .zshrc")
	fmt.println()
	fmt.println("  # Fastest startup (replace in .zshrc):")
	fmt.println(`  eval "$(wayu build eval)"`)
	fmt.println()
	fmt.println("  # This pre-computes PATH and exports everything")
	fmt.println("  # in a single command - no loops, no conditionals.")
	fmt.println()
	fmt.println("  # Measure impact on startup time:")
	fmt.println("  wayu build profile       # init-core vs full interactive shell")
	fmt.println()
}
