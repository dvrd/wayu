// profile.odin - Implementation of `wayu build profile`
//
// Extracted from main.odin (2026-04-24) per code review L1. Measures shell
// startup time by spawning the user's shell in a subprocess and timing it.
//
// The current build has two entry points in common:
//   - `profile_startup_performance()` — run N iterations per scenario,
//     print a min/mean/max table across (no-rc, wayu-init, turbo, full).
//   - `render_phase_breakdown_zsh()` — per-phase core.zsh timing,
//     useful for finding which wayu section costs the most ms at launch.
//
// Works for Bash/Zsh/Fish; resolves the shell binary via `which <shell>`
// before falling back to $SHELL.

package wayu

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

// How many iterations to run per scenario when profiling startup. 5 gives
// enough samples to compute a meaningful min/mean/max without keeping the
// user waiting. Bumped up only if there's <1 percent variance.
PROFILE_ITERATIONS :: 5

// Sample describes a single timed invocation.
ProfileSample :: struct {
	label:   string,
	command: []string,   // argv passed to the subprocess (no shell quoting)
	times_ms: [PROFILE_ITERATIONS]f64,
}

// Display shell startup profiling information.
//
// Before this was a stub that only rendered a pre-recorded zsh profile file.
// The real command now spawns the user's shell in a subprocess and measures
// wall time with Odin's `time.tick_now()`, running each scenario N times
// and reporting min/mean/max. Two scenarios:
//
//   1. `core` alone: `shell -c 'source $WAYU_CONFIG/core.{ext}'`
//      — what wayu itself adds to startup.
//   2. interactive shell: `shell -i -c exit` — total cost the user sees on
//      every new terminal. The difference is shell-builtin work
//      (rcfile parsing, compinit, etc.) plus anything the user hand-added
//      to ~/.zshrc / ~/.bashrc / ~/.config/fish/config.fish.
//
// Works for all three supported shells. No temp files, no instrumentation
// required in the user's init.
profile_startup_performance :: proc() {
	print_header("Shell Startup Performance", "📊")
	fmt.println()

	shell_bin, ok := resolve_profile_shell(wayu.shell)
	if !ok {
		print_error_simple("Could not find a %s binary on $PATH to profile", get_shell_name(wayu.shell))
		fmt.println("Install the shell or run 'wayu build profile' from an interactive session of that shell.")
		os.exit(EXIT_CONFIG)
	}
	defer delete(shell_bin)

	core_file := fmt.aprintf("%s/core.%s", wayu.data, wayu.shell_ext)
	defer delete(core_file)

	if !os.exists(core_file) {
		print_warning("core.%s not found — run 'wayu init' or any 'wayu path/alias/constants add' first.", wayu.shell_ext)
		fmt.println()
	}

	// Build the two scenarios. Keep command slices alive until after rendering.
	source_cmd := fmt.aprintf("source %s", core_file)
	defer delete(source_cmd)

	scenarios := []ProfileSample{
		{
			label   = fmt.tprintf("core.%s (sourced in -c)", wayu.shell_ext),
			command = []string{shell_bin, "-c", source_cmd},
		},
		{
			label   = "interactive shell (-i -c exit)",
			command = []string{shell_bin, "-i", "-c", "exit"},
		},
	}

	print_info("Shell: %s", shell_bin)
	print_info("Iterations per scenario: %d", PROFILE_ITERATIONS)
	if os.exists(core_file) do print_info("core file: %s", core_file)
	fmt.println()

	for &scenario in scenarios {
		for i in 0..<PROFILE_ITERATIONS {
			start := time.tick_now()
			_ = run_command(scenario.command)
			elapsed := time.tick_since(start)
			scenario.times_ms[i] = f64(time.duration_milliseconds(elapsed))
		}
		render_profile_sample(scenario)
	}

	// Per-phase breakdown — only implemented for zsh since it relies on
	// $EPOCHREALTIME (microsecond-precision builtin). bash 5+ has it too but
	// macOS ships bash 3.2; fish has no equivalent portable primitive. Users
	// of those shells still get the two-scenario totals above.
	if wayu.shell == .ZSH && os.exists(core_file) {
		render_phase_breakdown_zsh(shell_bin, core_file)
	}

	fmt.println()
	print_section("Interpretation", EMOJI_INFO)
	fmt.println("  • 'core' is what wayu itself costs; aim for <10ms.")
	fmt.println("  • 'interactive shell' includes wayu + shell rc + any user hooks.")
	fmt.println("  • Difference ≈ shell/builtin overhead (compinit, rcfile, etc.).")
	if wayu.shell == .ZSH {
		fmt.println("  • Phase breakdown marks where the core time is spent.")
	}
	fmt.println()
	print_section("Next steps", EMOJI_ACTION)
	fmt.println("  wayu export           Generate turbo.{ext} (compiled, 2-4x faster)")
	fmt.println("  wayu doctor           Health check and optimization hints")
	fmt.println()
}

// Render a per-phase timing breakdown of core.zsh.
//
// Strategy: split core by `# === <name> ===` markers into sections,
// generate a profiling wrapper that records $EPOCHREALTIME before and
// after each section, run it once under the user's zsh, parse `PHASE=...`
// lines from stdout, and print a sorted table (slowest first).
//
// $EPOCHREALTIME is a zsh builtin (with `zmodload zsh/datetime`) that
// yields floating-point seconds since epoch with microsecond resolution,
// so each phase timing is accurate enough to matter for anything over
// ~10us.
render_phase_breakdown_zsh :: proc(shell_bin, core_file: string) {
	content, ok := safe_read_file(core_file)
	if !ok do return
	defer delete(content)

	phases := split_init_core_by_markers(string(content))
	defer {
		for p in phases {
			delete(p.name)
			delete(p.body)
		}
		delete(phases)
	}
	if len(phases) == 0 do return

	// Build the instrumented script in memory, then hand it to zsh via -c
	// so we don't have to touch the filesystem.
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)

	fmt.sbprintln(&sb, "zmodload zsh/datetime 2>/dev/null || true")
	for p, i in phases {
		fmt.sbprintfln(&sb, "__wayu_t_%d_a=$EPOCHREALTIME", i)
		fmt.sbprint(&sb, p.body)
		fmt.sbprintln(&sb)
		fmt.sbprintfln(&sb, "__wayu_t_%d_b=$EPOCHREALTIME", i)
		// printf with %s keeps the floats as the shell printed them (locale
		// independent, no precision loss from another printf spec).
		fmt.sbprintfln(&sb, "printf 'PHASE=%%s|%%s|%%s\\n' %q \"$__wayu_t_%d_a\" \"$__wayu_t_%d_b\"", p.name, i, i)
	}

	out := capture_command([]string{shell_bin, "-c", strings.to_string(sb)})
	defer if len(out) > 0 do delete(out)
	if len(out) == 0 do return

	// Parse `PHASE=name|start|end` lines. Anything else is output from the
	// phase body itself (e.g. a plugin's banner) and is ignored here.
	PhaseTiming :: struct { name: string, ms: f64 }
	timings := make([dynamic]PhaseTiming, context.temp_allocator)
	for line in strings.split_lines(out) {
		if !strings.has_prefix(line, "PHASE=") do continue
		rest := line[len("PHASE="):]
		parts := strings.split(rest, "|")
		defer delete(parts)
		if len(parts) != 3 do continue
		start_s, ok_a := strconv.parse_f64(parts[1])
		end_s,   ok_b := strconv.parse_f64(parts[2])
		if !ok_a || !ok_b do continue
		append(&timings, PhaseTiming{
			name = parts[0],
			ms   = (end_s - start_s) * 1000.0,
		})
	}
	if len(timings) == 0 do return

	slice.sort_by(timings[:], proc(a, b: PhaseTiming) -> bool { return a.ms > b.ms })

	total_ms := 0.0
	for t in timings do total_ms += t.ms

	fmt.println()
	fmt.printfln("%sPhase breakdown (sorted by time, single run)%s", BOLD, RESET)
	for t in timings {
		share := 0.0
		if total_ms > 0 do share = (t.ms / total_ms) * 100.0
		// Odin's %N.1f zero-pads when N > natural width; sidestep with
		// manual space padding so the column stays neat.
		ms_str    := fmt.aprintf("%.1f", t.ms);    defer delete(ms_str)
		share_str := fmt.aprintf("%.1f", share);   defer delete(share_str)
		fmt.printfln("  %s ms  %s%%   %s", pad_left(ms_str, 6), pad_left(share_str, 4), t.name)
	}
	total_str := fmt.aprintf("%.1f", total_ms); defer delete(total_str)
	fmt.printfln("  %s ms  100.0%%   (sum)", pad_left(total_str, 6))
	fmt.println()
}

pad_left :: proc(s: string, width: int) -> string {
	if len(s) >= width do return s
	return fmt.tprintf("%s%s", strings.repeat(" ", width - len(s), context.temp_allocator), s)
}

InitCorePhase :: struct { name, body: string }

// Split core by `# === <name> ===` markers. Everything before the
// first marker (the shebang + comment header) becomes a synthetic
// "__prelude__" phase so it still gets timed; after that each marker
// starts a new phase whose body runs until the next marker or EOF.
// Returned strings are heap-allocated — caller owns them.
split_init_core_by_markers :: proc(content: string) -> []InitCorePhase {
	lines := strings.split(content, "\n")
	defer delete(lines)

	phases := make([dynamic]InitCorePhase)
	current_name := strings.clone("__prelude__")
	sb := strings.builder_make()

	flush :: proc(phases: ^[dynamic]InitCorePhase, name: ^string, sb: ^strings.Builder) {
		body := strings.clone(strings.to_string(sb^))
		append(phases, InitCorePhase{name = name^, body = body})
		name^ = ""
		strings.builder_reset(sb)
	}

	for line in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "# === ") && strings.has_suffix(trimmed, " ===") {
			flush(&phases, &current_name, &sb)
			name := trimmed[len("# === "):len(trimmed)-len(" ===")]
			current_name = strings.clone(name)
			continue
		}
		strings.write_string(&sb, line)
		strings.write_byte(&sb, '\n')
	}
	flush(&phases, &current_name, &sb)
	strings.builder_destroy(&sb)

	result := make([]InitCorePhase, len(phases))
	copy(result, phases[:])
	delete(phases)
	return result
}

// Compute min/mean/max from the populated times_ms and print a one-line
// summary per scenario plus the raw samples.
render_profile_sample :: proc(s: ProfileSample) {
	if PROFILE_ITERATIONS == 0 do return

	min_ms := s.times_ms[0]
	max_ms := s.times_ms[0]
	sum_ms := 0.0
	for t in s.times_ms {
		if t < min_ms do min_ms = t
		if t > max_ms do max_ms = t
		sum_ms += t
	}
	mean_ms := sum_ms / f64(PROFILE_ITERATIONS)

	fmt.printfln("%s%s%s", BOLD, s.label, RESET)
	fmt.printfln("  min  %.1f ms", min_ms)
	fmt.printfln("  mean %.1f ms", mean_ms)
	fmt.printfln("  max  %.1f ms", max_ms)
	fmt.printf("  raw  ")
	for t, i in s.times_ms {
		if i > 0 do fmt.printf(" ")
		fmt.printf("%.1f", t)
	}
	fmt.println(" ms")
	fmt.println()
}

// Pick the shell binary to spawn. Tries `which <shell>` first so we respect
// $PATH, then falls back to $SHELL (which is what wayu used to detect the
// shell in the first place). Returned string is heap-allocated and owned
// by the caller.
resolve_profile_shell :: proc(shell: ShellType) -> (string, bool) {
	name := ""
	switch shell {
	case .ZSH:  name = "zsh"
	case .BASH: name = "bash"
	case .FISH: name = "fish"
	case .UNKNOWN:
		// No explicit shell — skip the `which` probe and go straight to
		// the environment fallback below.
	}

	if len(name) > 0 {
		if path := capture_command([]string{"which", name}); len(path) > 0 {
			return path, true
		}
	}

	// Fallback: $SHELL — common on systems where the shell lives outside
	// $PATH (e.g. homebrew fish under /opt/homebrew/bin but $PATH not set
	// in the calling environment), or when DETECTED_SHELL was forced via
	// --shell but the binary isn't installed.
	env_shell := os.get_env("SHELL", context.temp_allocator)
	if len(env_shell) > 0 && os.exists(env_shell) {
		return strings.clone(env_shell), true
	}
	return "", false
}

