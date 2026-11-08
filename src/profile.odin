// profile.odin - Implementation of `wayu build profile`
//
// Extracted from main.odin (2026-04-24) per code review L1. Measures shell
// startup time by spawning the user's shell in a subprocess and timing it.
//
// The current build has two entry points in common:
//   - `profile_startup_performance()` — run N iterations per scenario,
//     print a min/mean/max table across (no-rc, wayu-init, turbo, full).
//   - `render_phase_breakdown()` — per-unit core.<ext> timing (zsh, bash 5+):
//     each core section, each [tools] entry (evalcache call or lazy recipe,
//     all inline in core since OKAMI-284) and each plugin
//     (from the inlined plugins.<ext>), so the slow tool/plugin is named.
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
	source_cmd := fmt.aprintf("source %s", shell_single_quote(core_file, context.temp_allocator))
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

	// Per-unit breakdown — needs $EPOCHREALTIME (microsecond-precision):
	// zsh (zsh/datetime) and bash 5+; macOS ships bash 3.2, and fish has no
	// equivalent portable primitive. Those still get the totals above.
	if (wayu.shell == .ZSH || wayu.shell == .BASH) && os.exists(core_file) {
		render_phase_breakdown(shell_bin, core_file, wayu.shell)
	}

	fmt.println()
	print_section("Interpretation", EMOJI_INFO)
	fmt.println("  • 'core' is what wayu itself costs; aim for <10ms.")
	fmt.println("  • 'interactive shell' includes wayu + shell rc + any user hooks.")
	fmt.println("  • Difference ≈ shell/builtin overhead (compinit, rcfile, etc.).")
	if wayu.shell == .ZSH || wayu.shell == .BASH {
		fmt.println("  • Phase breakdown marks where the core time is spent: per section,")
		fmt.println("    per [tools] entry ('tool …') and per plugin ('plugin …').")
	}
	fmt.println()
	print_section("Next steps", EMOJI_ACTION)
	fmt.println("  wayu export           Write turbo.{ext} (same as core, refreshed on build)")
	fmt.println("  wayu doctor           Health check and optimization hints")
	fmt.println()
}

// Render a per-unit timing breakdown of core.<ext> (OKAMI-180).
//
// Strategy: split core into units (profile_core_units: `# === <name> ===`
// sections, with plugins.<ext> inlined, split per tool / plugin), generate a script that records $EPOCHREALTIME before and after
// each unit, run it once under the user's shell, parse `PHASE=...` lines
// from stdout, and print a sorted table (slowest first).
//
// $EPOCHREALTIME (zsh with `zmodload zsh/datetime`, bash 5+) yields
// floating-point seconds since epoch with microsecond resolution, so each
// unit's timing is accurate enough to matter for anything over ~10us.
render_phase_breakdown :: proc(shell_bin, core_file: string, shell: ShellType) {
	content, ok := safe_read_file(core_file)
	if !ok do return
	defer delete(content)

	phases := profile_core_units(string(content), shell)
	defer {
		for p in phases {
			delete(p.name)
			delete(p.body)
		}
		delete(phases)
	}
	if len(phases) == 0 do return

	// Build the instrumented script in memory, then hand it to the shell
	// via -c so we don't have to touch the filesystem.
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)

	if shell == .ZSH {
		fmt.sbprintln(&sb, "zmodload zsh/datetime 2>/dev/null || true")
	}
	fmt.sbprintln(&sb, "[ -n \"${EPOCHREALTIME-}\" ] || { echo WAYU_NO_EPOCHREALTIME; exit 0; }")
	for p, i in phases {
		fmt.sbprintfln(&sb, "__wayu_t_%d_a=$EPOCHREALTIME", i)
		fmt.sbprint(&sb, p.body)
		fmt.sbprintln(&sb)
		fmt.sbprintfln(&sb, "__wayu_t_%d_b=$EPOCHREALTIME", i)
		// printf with %s keeps the floats as the shell printed them (locale
		// independent, no precision loss from another printf spec).
		fmt.sbprintfln(&sb, "printf 'PHASE=%%s|%%s|%%s\\n' %s \"$__wayu_t_%d_a\" \"$__wayu_t_%d_b\"",
			shell_single_quote(p.name, context.temp_allocator), i, i)
	}

	out := capture_command([]string{shell_bin, "-c", strings.to_string(sb)})
	defer if len(out) > 0 do delete(out)
	if len(out) == 0 do return
	if strings.contains(out, "WAYU_NO_EPOCHREALTIME") {
		fmt.println()
		print_info("Phase breakdown needs $EPOCHREALTIME (zsh, or bash 5+); %s has none.", shell_bin)
		return
	}

	// Parse `PHASE=name|start|end` lines. Anything else is output from the
	// phase body itself (e.g. a plugin's banner) and is ignored here.
	PhaseTiming :: struct { name: string, ms: f64 }
	timings := make([dynamic]PhaseTiming, context.temp_allocator)
	for line in strings.split_lines(out, context.temp_allocator) {
		if !strings.has_prefix(line, "PHASE=") do continue
		rest := line[len("PHASE="):]
		parts := strings.split(rest, "|", context.temp_allocator)
		if len(parts) != 3 do continue
		// Some locales print the decimal separator as ','.
		start_s, ok_a := strconv.parse_f64(epoch_decimal(parts[1]))
		end_s,   ok_b := strconv.parse_f64(epoch_decimal(parts[2]))
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

@(private = "file")
epoch_decimal :: proc(s: string) -> string {
	i := strings.index_byte(s, ',')
	if i < 0 do return s
	return fmt.tprintf("%s.%s", s[:i], s[i + 1:])
}

// Units to time in core.<ext>: one per `# === <name> ===` section (text
// before the first marker is "__prelude__"). The line that sources
// plugins.<ext> is replaced by that file's contents. Split further:
// `tool <name> (evalcache)` per `_wayu_evalcache` call, `tool <recipe>` per
// `# --- recipe: … ---` block, and `plugin <name>` per plugin block of the
// loader. Other `# --- … ---` markers (prompt features) name a sub-unit of
// their section. Units whose body has no code are dropped.
// Returned names/bodies are heap-allocated — caller owns them.
profile_core_units :: proc(content: string, shell: ShellType) -> [dynamic]InitCorePhase {
	ext := get_shell_extension(shell)
	plugins_q := shell_double_quote_literal(fmt.tprintf("%s/plugins.%s", wayu.data, ext), context.temp_allocator)
	ctx := ProfileSplit{
		units        = make([dynamic]InitCorePhase),
		plugins_line = fmt.tprintf("if [ -f %s ]; then source %s; fi", plugins_q, plugins_q),
		plugins_file = fmt.tprintf("%s/plugins.%s", wayu.data, ext),
		sb           = strings.builder_make(context.temp_allocator),
	}
	profile_split(&ctx, content, "", "__prelude__", 0)
	return ctx.units
}

@(private = "file")
ProfileSplit :: struct {
	units:        [dynamic]InitCorePhase,
	plugins_line: string,
	plugins_file: string,
	sb:           strings.Builder, // body of the current unit
	name:         string,          // name of the current unit (temp)
}

// Close the current unit; keep it when its body has code.
@(private = "file")
profile_flush :: proc(ctx: ^ProfileSplit) {
	body := strings.to_string(ctx.sb)
	has_code := false
	for l in strings.split_lines(body, context.temp_allocator) {
		t := strings.trim_space(l)
		if len(t) > 0 && !strings.has_prefix(t, "#") { has_code = true; break }
	}
	if has_code {
		append(&ctx.units, InitCorePhase{name = strings.clone(ctx.name), body = strings.clone(body)})
	}
	strings.builder_reset(&ctx.sb)
}

@(private = "file")
profile_split :: proc(ctx: ^ProfileSplit, content, prefix, first_name: string, depth: int) {
	section := first_name
	ctx.name = section
	for line in strings.split_lines(content, context.temp_allocator) {
		trimmed := strings.trim_space(line)
		switch {
		case strings.has_prefix(trimmed, "# === ") && strings.has_suffix(trimmed, " ==="):
			profile_flush(ctx)
			section = fmt.tprintf("%s%s", prefix, trimmed[len("# === "):len(trimmed) - len(" ===")])
			ctx.name = section
			continue
		case strings.has_prefix(trimmed, "# --- ") && strings.has_suffix(trimmed, " ---"):
			profile_flush(ctx)
			// `recipe: nvm (lazy)` → `tool nvm (lazy)`; the generic
			// `recipe: lazy (<name>)` → `tool <name> (lazy)`.
			raw := trimmed[len("# --- "):len(trimmed) - len(" ---")]
			if !strings.has_prefix(raw, "recipe: ") {
				ctx.name = fmt.tprintf("%s › %s", section, raw)
				continue
			}
			inner := raw[len("recipe: "):]
			if strings.has_prefix(inner, "lazy (") && strings.has_suffix(inner, ")") {
				inner = fmt.tprintf("%s (lazy)", inner[len("lazy ("):len(inner) - 1])
			}
			ctx.name = fmt.tprintf("%stool %s", prefix, inner)
			continue
		case strings.has_prefix(line, "_wayu_evalcache "):
			profile_flush(ctx)
			fields := strings.fields(line, context.temp_allocator)
			ctx.name = fmt.tprintf("%stool %s (evalcache)", prefix, fields[1])
			strings.write_string(&ctx.sb, line)
			strings.write_byte(&ctx.sb, '\n')
			profile_flush(ctx)
			ctx.name = section
			continue
		case depth > 0 && strings.has_prefix(trimmed, "# ") && strings.contains(trimmed, " (priority: "):
			profile_flush(ctx)
			ctx.name = fmt.tprintf("plugin %s", trimmed[2:strings.index(trimmed, " (priority: ")])
			continue
		case depth == 0 && line == ctx.plugins_line:
			data, ok := os.read_entire_file(ctx.plugins_file, context.temp_allocator)
			if ok != nil do continue // `[ -f ]` guard — nothing to load
			profile_flush(ctx)
			profile_split(ctx, string(data), "", "plugins (loader)", depth + 1)
			profile_flush(ctx)
			ctx.name = section
			continue
		}
		strings.write_string(&ctx.sb, line)
		strings.write_byte(&ctx.sb, '\n')
	}
	profile_flush(ctx)
}

pad_left :: proc(s: string, width: int) -> string {
	if len(s) >= width do return s
	return fmt.tprintf("%s%s", strings.repeat(" ", width - len(s), context.temp_allocator), s)
}

InitCorePhase :: struct { name, body: string }

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

