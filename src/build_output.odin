// build_output.odin - Build command output helpers

package wayu

import "core:fmt"
import "core:os"
import "core:strings"

// generate_eval_output_optimized generates all optimized init files and prints the source command.
generate_eval_output_optimized :: proc() {
	generate_optimized_init_all()

	core_file := fmt.aprintf("%s/init-core.zsh", g_ctx.wayu_config)
	defer delete(core_file)

	fmt.printfln(`source "%s"`, core_file)
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
