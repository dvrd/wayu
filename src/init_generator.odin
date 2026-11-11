// init_generator.odin - Optimized shell init file generation
package wayu
import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
// Best-effort write for generated init files. Logs a warning on failure
// instead of silently swallowing the error. Atomic, so a shell starting
// mid-regeneration never sources a truncated file. Generated core.<ext>
// files embed [env] values, so they are owner-only (0600); the chmod also
// repairs files created 0644 by older versions (OKAMI-206).
//
// zsh uses <file>.zwc when its mtime is >= the source's, compared in whole
// seconds. So: unchanged content is not rewritten (a valid .zwc stays
// usable), and a rewrite deletes the .zwc — otherwise a digest compiled in
// the same second from the previous content would shadow the new file.
write_init_file :: proc(path, content: string) {
	zwc := fmt.tprintf("%s.zwc", path)
	if old, err := os.read_entire_file(path, context.allocator); err == nil {
		same := string(old) == content
		delete(old)
		if same {
			restrict_file_mode(path)
			if os.exists(zwc) {
				restrict_file_mode(zwc)
			}
			return
		}
	}
	if !replace_zsh_source(path, content) {
		print_warning("Failed to write %s", path)
		return
	}
	restrict_file_mode(path)
}

// Atomically replace a file zsh may load through a .zwc digest, deleting the
// digest first, under the config lock. The background zcompile
// (flush_zcompile_batch) takes the same lock to check its snapshot and
// install the digest, so a digest of the old content can never sit next to
// the new file: deleting it after the rename left a window where a shell
// starting in the same second sourced the old digest, and a background
// install racing the rewrite could land after the delete (OKAMI-293).
replace_zsh_source :: proc(path, content: string) -> bool {
	locked := config_lock_acquire()
	defer if locked {
		config_lock_release()
	}
	_ = os.remove(fmt.tprintf("%s.zwc", path))
	return write_file_atomic(path, transmute([]byte)content) == nil
}

// What keeps the generated init fast (see generate_core_content):
//   - one file: init.<ext> sources core.<ext> only (OKAMI-284)
//   - zcompile: core.zsh and the compinit dump are compiled to .zwc
//   - [tools]: evalcache'd output, lazy wrappers, built-in zsh-defer
//   - compinit -C: the dump is rebuilt only when wayu's completions or an
//     fpath dir changed; later compinit calls are guarded (emit_zsh_completions)
//   - zsh: plugins, zsh-defer, compinit and the prompt in interactive shells
//     only; the prompt is rendered without command substitution

// --------------------------------------------------------------------------
// Cached wayu.toml content — shared across all commands in a single
// invocation to avoid redundant reads.  Lazy-loaded on first call; cleared
// by regenerate_init_core_silently (before regen) and generate_optimized_init_all.
// --------------------------------------------------------------------------
TOML_CONTENT_CACHE: struct {
	content: string,
	loaded:  bool,
	owned:   bool, // true when content was heap-allocated
} = {}

get_cached_toml_content :: proc() -> (string, bool) {
	if TOML_CONTENT_CACHE.loaded {
		if len(TOML_CONTENT_CACHE.content) == 0 {
			return "", false
		}
		return TOML_CONTENT_CACHE.content, true
	}

	config_path := fmt.aprintf("%s/wayu.toml", wayu.config)
	defer delete(config_path)

	TOML_CONTENT_CACHE.loaded = true
	// A missing wayu.toml is a normal state here (main pre-warms this cache
	// before `wayu init` creates it); safe_read_file would print
	// "ERROR: File not found" for it. Callers that require the file report
	// it themselves (check_wayu_initialized).
	if !os.exists(config_path) {
		return "", false
	}
	raw, ok := safe_read_file(config_path)
	if !ok {
		return "", false
	}

	TOML_CONTENT_CACHE.content = string(raw)
	TOML_CONTENT_CACHE.owned = true
	return TOML_CONTENT_CACHE.content, true
}

clear_toml_content_cache :: proc() {
	if TOML_CONTENT_CACHE.owned && len(TOML_CONTENT_CACHE.content) > 0 {
		delete(TOML_CONTENT_CACHE.content)
	}
	TOML_CONTENT_CACHE = {}
}

// --------------------------------------------------------------------------
// Batched zcompile — collect paths, compile in one shell invocation.
// --------------------------------------------------------------------------
@(private = "file")
ZCOMPILE_BATCH: [dynamic]string

// Queue a path for zcompile (batched). The path is cloned (heap) into the
// queue, so the caller may free its copy right away; flush_zcompile_batch
// frees the queued clones.
zcompile_file :: proc(path: string) {
	if wayu.shell != .ZSH {
		return
	}
	// Process-lifetime queue: heap, not the caller's context.allocator (a
	// unit test's tracking allocator reported unflushed entries as leaks).
	context.allocator = runtime.heap_allocator()
	append(&ZCOMPILE_BATCH, strings.clone(path))
}

// Flush all queued zcompile paths in a single zsh invocation.
//
// Paths are passed as positional arguments to `zsh -fc` (each one
// single-quoted for the outer `sh -c`), so spaces, quotes or `$` in
// $HOME / XDG paths can neither break the command nor inject code.
// Only zsh files are ever queued (zcompile_file checks the shell at queue
// time), so the batch is flushed whatever shell is active afterwards.
flush_zcompile_batch :: proc() {
	if len(ZCOMPILE_BATCH) == 0 {
		return
	}
	context.allocator = runtime.heap_allocator()

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	// Compile to a temp digest then rename: zcompile writes in place, and a
	// shell starting meanwhile would source a half-written .zwc
	// ("invalid zwc file"). The digest is compiled from a snapshot of $f
	// in a private temp dir (same name: zsh keys the digest by name), and
	// moved next to $f only under the config lock ($1) and only if $f still
	// holds that snapshot: nothing is written beside $f outside the lock, so
	// `plugin rm` (which holds it) never races a new file into the dir. Writers delete the .zwc and replace $f under the same lock
	// (replace_zsh_source), so a digest never outlives its content: zsh
	// prefers a .zwc not older than its source, in whole seconds (OKAMI-293).
	// The temp digest is removed if the compile is interrupted (trap), and
	// temp digests older than a minute — left by a compile killed hard, e.g.
	// with its terminal — are swept first.
	strings.write_string(
		&builder,
		`zsh -fc 'umask 077; zmodload zsh/mapfile zsh/system || exit 1; l=$1; shift; t=; d=; trap '\''rm -rf -- "$t" "$d"; exit 1'\'' HUP INT TERM; for f; do [[ -f $f ]] || continue; rm -f -- $f.<->.tmp.zwc(Nmm+1); d="${TMPDIR:-/tmp}/wayu-zc.$$.$RANDOM"; n=${f:t}; c=$mapfile[$f]; if mkdir -m 700 -- "$d" && mapfile[$d/$n]=$c && zcompile -- "$d/$n.zwc" "$d/$n" && zsystem flock -t 10 -f fd -- "$l"; then [[ $mapfile[$f] == "$c" ]] && t="$f.$$.tmp.zwc" && mv -f -- "$d/$n.zwc" "$t" && mv -f -- "$t" "$f.zwc"; zsystem flock -u $fd; fi; rm -rf -- "$t" "$d"; t= d=; done' zsh`,
	)
	lock_dir := wayu.data // the config lock always lives in the data dir (OKAMI-327)
	strings.write_byte(&builder, ' ')
	strings.write_string(
		&builder,
		shell_single_quote(
			fmt.tprintf("%s/%s", lock_dir, CONFIG_LOCK_FILE),
			context.temp_allocator,
		),
	)
	for p in ZCOMPILE_BATCH {
		strings.write_byte(&builder, ' ')
		strings.write_string(&builder, shell_single_quote(p, context.temp_allocator))
	}
	strings.write_string(&builder, " >/dev/null 2>&1")

	// Fire-and-forget: fork a child to run zcompile in background.
	// The parent returns immediately. Zcompile is a non-critical
	// startup optimization; if it fails, zsh just sources the .zsh text.
	run_background_shell(strings.to_string(builder))

	for p in ZCOMPILE_BATCH {delete(p)}
	clear(&ZCOMPILE_BATCH)
}

// Absolute path of a generated runtime file: <data>/<base>.<ext>.
// Allocated with the temp allocator.
@(private = "file")
runtime_file :: proc(base: string) -> string {
	return fmt.tprintf("%s/%s.%s", wayu.data, base, get_shell_extension(wayu.shell))
}

// `if [ -f "<file>" ]; then source "<file>"; fi` (status 0 when absent) with the path safely quoted.
@(private = "file")
emit_source_if_exists :: proc(b: ^strings.Builder, file: string) {
	q := shell_double_quote_literal(file, context.temp_allocator)
	fmt.sbprintfln(b, "if [ -f %s ]; then source %s; fi", q, q)
}

// Shells whose generated files are refreshed on every (re)generation: the
// active shell first, then every other shell already set up in the data dir
// (init.<ext> or core.<ext> exists). Regenerating only $SHELL's files left a
// bash setup stale when wayu ran with SHELL=zsh (and vice versa), so open and
// new shells of the other kind never saw path/alias/env changes.
shells_to_generate :: proc() -> (out: [4]ShellType, n: int) {
	out[0] = wayu.shell
	n = 1
	for s in ([]ShellType{.ZSH, .BASH, .FISH}) {
		if s == wayu.shell {
			continue
		}
		ext := get_shell_extension(s)
		if os.exists(fmt.tprintf("%s/init.%s", wayu.data, ext)) ||
		   os.exists(fmt.tprintf("%s/core.%s", wayu.data, ext)) {
			out[n] = s
			n += 1
		}
	}
	return
}

// Generate every runtime file for the ACTIVE shell (wayu.shell): core.<ext>
// + path_sync.<ext> (fish has its own native generator); with `plugins`
// also plugins.<ext> from plugins.json (`wayu build`, `wayu init`;
// OKAMI-309), else only the zsh plugin keybindings (plugins/config.zsh).
@(private = "file")
generate_runtime_files_for_active_shell :: proc(plugins := false) -> (plugins_ok: bool) {
	// Generators use the temp arena for quoting; roll it back per shell so
	// regenerating several shells doesn't multiply temp usage.
	has_arena := wayu.temp_arena != nil
	arena_mark: virtual.Arena_Temp
	if has_arena {
		arena_mark = virtual.arena_temp_begin(wayu.temp_arena)
	}
	defer if has_arena {
		virtual.arena_temp_end(arena_mark)
	}
	if wayu.shell == .FISH {
		generate_core_init_fish()
	} else {
		generate_core_init_v2()
	}
	if plugins {
		plugins_ok = generate_plugins_file(wayu.shell)
	} else {
		plugins_ok = generate_plugins_runtime_config(wayu.shell)
	}
	// Keep init.{ext} in sync with the current orchestrator template.
	sync_init_orchestrator()
	return
}

// Silently regenerate every runtime file sourced by init.{ext} after any
// mutation (path/alias/constants add/remove, template apply, hot reload),
// for every initialized shell (see shells_to_generate).
//
// Unlike generate_optimized_init_all this version emits no log output so it
// can be called on every CLI write without adding noise. Missing wayu.toml
// or empty configs are treated as no-ops; errors during generation are
// swallowed because the CLI already printed the user-visible success and
// we don't want a secondary "regen failed" line to confuse things.
regenerate_init_core_silently :: proc() {
	if wayu.dry_run do return

	// Only makes sense when there's a wayu.toml to read from - without it
	// the generators would just write empty files.
	toml_path := fmt.aprintf("%s/wayu.toml", wayu.config)
	defer delete(toml_path)
	if !os.exists(toml_path) do return

	// Invalidate stale cache BEFORE generation so generators read the
	// current wayu.toml.
	clear_toml_content_cache()

	shells, n := shells_to_generate()
	saved_shell, saved_ext := wayu.shell, wayu.shell_ext
	for s in shells[:n] {
		wayu.shell = s
		wayu.shell_ext = get_shell_extension(s)
		_ = generate_runtime_files_for_active_shell()
	}
	wayu.shell, wayu.shell_ext = saved_shell, saved_ext

	// Flush cached resources after all generators have run.
	clear_toml_content_cache()
	// Recompile the rewritten zsh files in the background (fire-and-forget,
	// the CLI doesn't wait). write_init_file deleted their now-stale .zwc;
	// without this the bytecode speedup was gone after the first mutation
	// until the next explicit `wayu init` / `build`.
	flush_zcompile_batch()
}

// fnv64a of the init.{zsh,bash,fish} templates this wayu writes and of the
// ones the previous develop build wrote. Only a file byte-identical to one
// of them is an untouched wayu orchestrator, which sync_init_orchestrator
// refreshes. When INIT_TEMPLATE_* changes, replace the "previous" hashes
// with the current ones and add the new template's hash (unit-tested: every
// template currently shipped must be listed).
KNOWN_INIT_TEMPLATE_HASHES :: [?]u64 {
	// zsh: previous, current
	0x96ea40ba08bbab77,
	0xa898eeefc79dbe01,
	// bash: previous, current
	0xb2b8327b7b68ed26,
	0x5b5f29c251fbdb06,
	// fish: previous, current
	0xfda840b65f7815f1,
	0x1815574ae9245a00,
}

is_known_init_template :: proc(content: string) -> bool {
	h := hash.fnv64a(transmute([]byte)content)
	known := KNOWN_INIT_TEMPLATE_HASHES
	return slice.contains(known[:], h)
}

// Rewrite init.{ext} with the current template when it is an unmodified copy
// of a known template (KNOWN_INIT_TEMPLATE_HASHES). `wayu init` only creates init.{ext}
// when missing, so without this existing users never receive orchestrator
// fixes (e.g. the fast path that double-sourced extra/tools). The old file is
// backed up first. A file the user edited is never rewritten (OKAMI-235): a
// warning on stderr says how to adopt the new template.
sync_init_orchestrator :: proc() {
	if wayu.dry_run do return
	path := fmt.aprintf("%s/init.%s", wayu.data, get_shell_extension(wayu.shell))
	defer delete(path)
	if !os.exists(path) do return

	template := get_init_template(wayu.shell)
	data, ok := safe_read_file(path)
	if !ok do return
	defer delete(data)
	current := string(data)
	if current == template do return
	if !strings.contains(current, "Wayu Shell Initialization") do return

	if !is_known_init_template(current) {
		warn_customized_init(path, current)
		return
	}
	backup_path, backed_up := create_backup(path)
	if !backed_up {
		fmt.eprintfln("wayu: warning: could not back up %s; leaving it unchanged", path)
		return
	}
	delete(backup_path)
	cleanup_old_backups(path, 5)
	write_init_file(path, template)
}

// Tell the user once per distinct edited content that their init.{ext} is
// kept as-is. Goes to stderr (stdout stays clean for callers that capture it). The
// "already warned" marker is only recorded when stderr is a terminal, so a
// warning swallowed by the prompt hook's background `wayu build` (output
// discarded) is repeated where a human can see it.
@(private = "file")
warn_customized_init :: proc(path, current: string) {
	if wayu.tui_mode do return
	marker := fmt.tprintf("%s/.%s.customized", wayu.data, filepath.base(path))
	sig := fmt.tprintf("%x\n", hash.fnv64a(transmute([]byte)current))
	if old, err := os.read_entire_file(marker, context.temp_allocator);
	   err == nil && string(old) == sig {
		return
	}
	fmt.eprintfln("wayu: %s has local edits; not updating it to the current template.", path)
	fmt.eprintfln("wayu:   to adopt the new template: move it aside, then run `wayu init`.")
	if is_tty(2) {
		_ = write_file_atomic(marker, transmute([]byte)sig)
	}
}

// Generate all optimized init files (v2 with all optimizations) for every
// initialized shell (see shells_to_generate), printing what was written as
// `#` comments (harmless if stdout is captured into a shell). `plugins`:
// also regenerate plugins.<ext> from plugins.json.
generate_optimized_init_all :: proc(plugins := true) {
	shells, n := shells_to_generate()

	if wayu.dry_run {
		fmt.println("# [DRY RUN] No files written. Would generate:")
		for s in shells[:n] {
			for base in ([]string{"core", "path_sync"}) {
				fmt.printfln("#   %s/%s.%s", wayu.data, base, get_shell_extension(s))
			}
		}
		return
	}

	saved_shell, saved_ext := wayu.shell, wayu.shell_ext
	any_zsh := false
	for s in shells[:n] {
		wayu.shell = s
		wayu.shell_ext = get_shell_extension(s)
		if !generate_runtime_files_for_active_shell(plugins) {
			print_warning("Failed to generate plugins.%s", wayu.shell_ext)
		}
	}
	wayu.shell, wayu.shell_ext = saved_shell, saved_ext

	// Flush cached resources after all generators have run.
	clear_toml_content_cache()
	flush_zcompile_batch()

	for s in shells[:n] {
		ext := get_shell_extension(s)
		any_zsh = any_zsh || s == .ZSH
		fmt.println("# Init files generated:")
		fmt.printfln("#   %s/core.%s       (everything init.%s loads)", wayu.data, ext, ext)
		fmt.printfln("#   %s/path_sync.%s  (live PATH sync)", wayu.data, ext)
	}
	if any_zsh {
		fmt.println("#")
		fmt.println("# core.zsh is compiled to bytecode (core.zsh.zwc) in the background.")
	}
}

// Emit `export NAME="value"` lines for [env]. Values keep $VAR expansion,
// a leading `~/` becomes `$HOME/`, and `"`, `\`, backtick and `$(` are
// escaped (see shell_double_quote_env). Invalid names are skipped.
// `mask` replaces secret-looking values with SECRET_MASK (dry-run previews).
emit_env_exports :: proc(b: ^strings.Builder, sep: string = "\n", mask := false) {
	toml_env := read_env_values()
	defer {
		for e in toml_env {delete(e.name); delete(e.value)}
		delete(toml_env)
	}
	for e in toml_env {
		if !is_shell_var_name(e.name) {
			fmt.sbprintf(b, "# wayu: skipping invalid env name %q%s", e.name, sep)
			continue
		}
		// A protected name stored by hand (doctor reports it) is not set.
		if len(protected_env_name_error(e.name)) > 0 {
			fmt.sbprintf(b, "# wayu: skipping protected env name %s%s", e.name, sep)
			continue
		}
		v := expand_leading_tilde_to_home_var(e.value, context.temp_allocator)
		if mask {
			v = mask_secret_value(e.name, e.value)
		}
		fmt.sbprintf(
			b,
			"export %s=%s%s",
			e.name,
			shell_double_quote_env(v, context.temp_allocator),
			sep,
		)
	}
}

// Emit `alias name='command'` lines for [aliases]. Single quotes keep the
// command verbatim so `$VAR` expands when the alias runs.
emit_alias_definitions :: proc(b: ^strings.Builder, sep: string = "\n") {
	toml_aliases := read_alias_values()
	defer {
		for a in toml_aliases {delete(a.name); delete(a.command)}
		delete(toml_aliases)
	}
	for a in toml_aliases {
		if !is_safe_alias_name(a.name) {
			fmt.sbprintf(b, "# wayu: skipping invalid alias name %q%s", a.name, sep)
			continue
		}
		fmt.sbprintf(
			b,
			"alias %s=%s%s",
			a.name,
			shell_single_quote(a.command, context.temp_allocator),
			sep,
		)
	}
}

// `wayu export --eval`: put the [paths] dirs (file order = priority) in
// front of PATH, as one `;`-separated statement list (it must survive the
// unquoted `eval $(...)` form). Values are expanded by the SHELL
// (path_value_shell_word: `$FZG/bin` uses the shell's FZG, an unset variable
// drops the entry); entries that are not directories or contain ':' are
// skipped and duplicates dropped, like core.<ext>. Returns false when
// [paths] has no entries.
emit_path_eval :: proc(b: ^strings.Builder, sep: string = "\n") -> bool {
	values := read_path_values()
	script_path_prepend(&values) // <data>/bin first (`wayu script`)
	defer {
		for v in values {delete(v)}
		delete(values)
	}
	if len(values) == 0 {
		return false
	}
	fmt.sbprint(b, "_wayu_np=; for _wayu_p in")
	for v in values {
		fmt.sbprint(b, " ")
		fmt.sbprint(b, path_value_shell_word(v))
	}
	fmt.sbprint(
		b,
		`; do case "$_wayu_p" in ''|*:*) continue ;; esac; if [ -d "$_wayu_p" ]; then case ":$_wayu_np:" in *":$_wayu_p:"*) ;; *) _wayu_np="${_wayu_np:+$_wayu_np:}$_wayu_p" ;; esac; fi; done; `,
	)
	fmt.sbprintf(
		b,
		`if [ -n "$_wayu_np" ]; then export PATH="$_wayu_np:$PATH"; fi; unset _wayu_p _wayu_np%s`,
		sep,
	)
	return true
}

// Source every user function file (zsh null-glob vs bash nullglob-free loop).
// zsh: the glob runs in an anonymous function under `emulate -L zsh` so the
// user's NO_BARE_GLOB_QUAL / NO_GLOB / KSH_ARRAYS can't break it (OKAMI-224);
// the files are sourced outside it so they run with the user's own options.
// `wayu function add` writes functions/<name>.<ext> per shell; each shell
// sources only its own extension (*.zsh / *.bash).
emit_functions_loader :: proc(b: ^strings.Builder) {
	dir := shell_double_quote_literal(
		fmt.tprintf("%s/functions", wayu.data),
		context.temp_allocator,
	)
	if wayu.shell == .ZSH {
		fmt.sbprintfln(
			b,
			`() {{ emulate -L zsh; typeset -ga _wayu_fn_files; _wayu_fn_files=( %s/*.zsh(N-.) ) }}`,
			dir,
		)
		fmt.sbprintln(b, `for _wayu_f in "${_wayu_fn_files[@]}"; do source "$_wayu_f"; done`)
		fmt.sbprintln(b, `unset _wayu_f _wayu_fn_files`)
	} else {
		emit_bash_glob_source(b, dir, {"*.bash"})
	}
}

// bash: source every file matching `patterns` in `dir_q` (an already quoted
// dir). The glob runs with failglob off and globbing on (a user's
// `shopt -s failglob` made every start print "no match", OKAMI-345; `set -f`
// skipped the files), both restored before the files are sourced, so they
// run with the user's options. nullglob and `set -u` safe (bash 3.2 too).
emit_bash_glob_source :: proc(b: ^strings.Builder, dir_q: string, patterns: []string) {
	fmt.sbprintfln(b, "if [ -d %s ]; then", dir_q)
	fmt.sbprintln(b, "  _wayu_fg=0 _wayu_nf=0")
	fmt.sbprintln(b, "  if shopt -q failglob; then _wayu_fg=1; shopt -u failglob; fi")
	fmt.sbprintln(b, "  case $- in *f*) _wayu_nf=1; set +f ;; esac")
	fmt.sbprint(b, "  _wayu_files=(")
	for pat in patterns {
		fmt.sbprintf(b, " %s/%s", dir_q, pat)
	}
	fmt.sbprintln(b, " )")
	fmt.sbprintln(b, `  [ "$_wayu_fg" = 0 ] || shopt -s failglob`)
	fmt.sbprintln(b, `  [ "$_wayu_nf" = 0 ] || set -f`)
	fmt.sbprintln(
		b,
		`  for _wayu_f in ${_wayu_files[@]+"${_wayu_files[@]}"}; do if [ -f "$_wayu_f" ]; then source "$_wayu_f"; fi; done`,
	)
	fmt.sbprintln(b, "  unset _wayu_f _wayu_files _wayu_fg _wayu_nf")
	fmt.sbprintln(b, "fi")
}

// Live PATH sync (replaces the old `wayu()` shell-function wrapper, which
// shadowed the binary in `where`/`type` and only handled `path add`).
//
// core sources $data/path_sync.<ext>, whose FIRST LINE is a signature of the
// [paths] list. A prompt hook reads just that line with the `read` builtin (no
// fork) and re-sources the file only when it changed, so `wayu path add/rm`
// and TUI edits reach already-open shells at the next prompt.
//
// Hand edits of wayu.toml (or a restored entries.json): the hook also
// compares mtimes (`-nt`, a builtin test, no fork). When wayu.toml or
// entries.json is newer than path_sync it runs
// `wayu build` once (regenerating every initialized shell's files; with
// WAYU_PROMPT_HOOK=1 stale scripts are compiled in the background, not
// while the prompt waits, OKAMI-308), using
// _WAYU_BIN — the binary that generated core — so a dev build sourced from
// .zshenv isn't regenerated by an older wayu earlier on PATH (e.g.
// Homebrew). A hand-edited PATH entry thus reaches open shells at their next
// prompt too.
// If that regeneration does not refresh path_sync (a malformed hand save,
// wayu missing, write error) the hook writes the marker
// path_sync.<ext>.regen-failed (a redirection, no fork) and retries only
// once wayu.toml or entries.json is not older than the marker, i.e. after
// the next save (OKAMI-344: one failure used to stop the sync for good). Not
// older, not newer: bash 3.2 compares whole seconds, so a save in the
// marker's second still retries. Only when the marker can't be written
// does the shell stop retrying (_WAYU_PATHS_REGEN=0).
// Only [paths] is live-synced; [env]/[aliases]/[tools] changes apply to new
// shells (or `source` init again).
//
// _wayu_paths_apply <sig> <dir>...:
//   dirs that are empty, contain ':' / a newline, or are not directories are
//   ignored; the rest is the wanted list (file order = priority).
//   _WAYU_PATHS_MANAGED (exported, so nested shells inherit it) holds only
//   the dirs wayu itself put on PATH: wanted dirs that were NOT already on
//   PATH (system / parent-provided dirs are never "managed"), plus dirs that
//   were already managed. Only managed dirs are ever removed, so dropping a
//   wayu entry never strips a dir the system also provides.
//   first call (shell startup): drop stale managed dirs, then put the wanted
//   dirs first in order (wayu order wins) — same as `PATH="a:b:$PATH"`.
//   later calls: drop managed dirs no longer wanted; insert each missing
//   wanted dir right after the previous wanted dir (front if it is the
//   first), i.e. the position a new shell would give it relative to the
//   other wayu dirs; leave everything else in place (so tools that
//   prepended after startup, e.g. nvm, keep their position).
//   first prompt (zsh): restore the startup order once. A login shell runs
//   /etc/zprofile after .zshenv, and macOS path_helper there moves the
//   system dirs ahead of everything, so wayu loaded from .zshenv lost its
//   precedence. _wayu_paths_restore puts the wayu dirs back in front of
//   every dir that was already on PATH when wayu loaded or that path_helper
//   manages (/etc/paths, /etc/paths.d — read without forking); other dirs
//   added after that (e.g. prepended in .zshrc) keep their place ahead.
//   `zsh -l -c CMD` / `-l -i -c` never draw a prompt (IDEs resolving the
//   login env, ssh commands): there a TRAPDEBUG (WAYU_PATH_LOGIN_RESTORE_ZSH,
//   set at the end of core only in that case) runs the restore before the
//   first command of CMD (ZSH_EVAL_CONTEXT cmdarg:*, i.e. after every
//   startup file) and removes itself (OKAMI-318).
// Both hooks preserve $? (prompt commands after them read it) and are
// `set -u` / nounset safe.
WAYU_PATH_SYNC_ZSH :: `_wayu_paths_apply() {
  emulate -L zsh
  local first=0 d prev="" i
  [[ -n "${_WAYU_PATHS_SIG-}" ]] || first=1
  typeset -g _WAYU_PATHS_SIG="# wayu-paths $1"
  shift
  local -a want keep managed old=( ${(s.:.)${_WAYU_PATHS_MANAGED-}} )
  for d in "$@"; do
    [[ -n $d && $d != *:* && $d != *$'\n'* && -d $d ]] || continue
    (( ${want[(Ie)$d]} )) || want+=( "$d" )
  done
  for d in $want; do
    (( ${old[(Ie)$d]} || ! ${path[(Ie)$d]} )) && managed+=( "$d" )
  done
  for d in $path; do
    (( ${old[(Ie)$d]} && ! ${want[(Ie)$d]} )) && continue
    (( first && ${want[(Ie)$d]} )) && continue
    (( ${keep[(Ie)$d]} )) || keep+=( "$d" )
  done
  if (( first )); then
    keep=( $want $keep )
    typeset -ga _wayu_paths_want=( $want ) _wayu_paths_seen=( $keep )
  else
    for d in $want; do
      if (( ! ${keep[(Ie)$d]} )); then
        if [[ -z $prev ]]; then
          keep=( "$d" $keep )
        else
          i=${keep[(Ie)$prev]}
          keep=( "${(@)keep[1,i]}" "$d" "${(@)keep[i+1,-1]}" )
        fi
      fi
      prev=$d
    done
  fi
  path=( $keep )
  typeset -gx _WAYU_PATHS_MANAGED="${(j.:.)managed}"
  export PATH
}
_wayu_paths_restore() {
  emulate -L zsh
  local d f i=0 n=0
  local -a rest present=( ${_wayu_paths_want:*path} ) seen=( $_wayu_paths_seen )
  for f in /etc/paths(N) /etc/paths.d/*(N); do
    seen+=( ${(f)"$(<$f)"} )
  done
  for d in $path; do
    (( ${_wayu_paths_want[(Ie)$d]} )) || rest+=( "$d" )
  done
  for d in $rest; do
    (( ++n ))
    if (( ${seen[(Ie)$d]} )); then i=$n; break; fi
  done
  (( i )) || i=$(( ${#rest} + 1 ))
  path=( "${(@)rest[1,i-1]}" $present "${(@)rest[i,-1]}" )
  export PATH
  unset _wayu_paths_seen _wayu_paths_want
}
# No emulate -L here: its local_traps would bring the trap back on return.
_wayu_paths_debug() {
  [[ $ZSH_EVAL_CONTEXT == cmdarg:* ]] || return 0
  [[ ${functions[TRAPDEBUG]-} == *_wayu_paths_debug* ]] && unfunction TRAPDEBUG
  (( ${+_wayu_paths_seen} )) && _wayu_paths_restore
  return 0
}
_wayu_paths_sync() {
  local s=$? l
  (( ${+_wayu_paths_seen} )) && _wayu_paths_restore
  if [[ ${_WAYU_PATHS_REGEN-1} == 1 && ( ${_WAYU_TOML_FILE-} -nt $_WAYU_PATHS_FILE || ${_WAYU_ENTRIES_FILE-} -nt $_WAYU_PATHS_FILE ) ]] &&
     [[ ! -e $_WAYU_PATHS_FILE.regen-failed || ! ${_WAYU_TOML_FILE-} -ot $_WAYU_PATHS_FILE.regen-failed || ! ${_WAYU_ENTRIES_FILE-} -ot $_WAYU_PATHS_FILE.regen-failed ]]; then
    WAYU_PROMPT_HOOK=1 command "${_WAYU_BIN:-wayu}" build </dev/null >/dev/null
    if [[ ${_WAYU_TOML_FILE-} -nt $_WAYU_PATHS_FILE || ${_WAYU_ENTRIES_FILE-} -nt $_WAYU_PATHS_FILE ]]; then
      { : >| $_WAYU_PATHS_FILE.regen-failed } 2>/dev/null || typeset -g _WAYU_PATHS_REGEN=0
    fi
  fi
  { read -r l < "$_WAYU_PATHS_FILE" } 2>/dev/null || return $s
  [[ "$l" == "${_WAYU_PATHS_SIG-}" ]] || source "$_WAYU_PATHS_FILE"
  return $s
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd _wayu_paths_sync
`

// zsh login shell running a -c command (see WAYU_PATH_SYNC_ZSH): restore
// the wayu PATH order before the command runs. Not when a TRAPDEBUG exists.
WAYU_PATH_LOGIN_RESTORE_ZSH :: `if [[ -o login && -n ${ZSH_EXECUTION_STRING-} ]] && (( ${+_wayu_paths_seen} && ! ${+functions[TRAPDEBUG]} )); then
  TRAPDEBUG() { _wayu_paths_debug }
fi
`

// bash 3.2 compatible: no associative arrays, so membership tests use
// ":a:b:" strings (safe because entries never contain ':'), and empty
// arrays are expanded as ${a[@]+"${a[@]}"} for `set -u`. Lists are split
// with IFS=':' under `set -f` (restored after) — `read -a <<<` here-strings
// cost a temp file each in bash 3.2 — and the `*":$d:"*` membership tests
// run in the C locale (byte compare; 5x faster than bash 3.2's multibyte
// matcher on long PATHs). These were most of core.bash's startup time.
WAYU_PATH_SYNC_BASH :: `_wayu_paths_apply() {
  local LC_ALL=C first=0 d e prev="" IFS=':' nl='
' glob=0
  case $- in *f*) ;; *) glob=1; set -f ;; esac
  [ -n "${_WAYU_PATHS_SIG-}" ] || first=1
  _WAYU_PATHS_SIG="# wayu-paths $1"
  shift
  local want=":" old=":${_WAYU_PATHS_MANAGED-}:" now=":$PATH:" managed=":" keep=":" out
  local -a cur ks
  for d in "$@"; do
    case "$d" in ""|*:*|*"$nl"*) continue ;; esac
    [ -d "$d" ] || continue
    case "$want" in *":$d:"*) continue ;; esac
    want="$want$d:"
    case "$old" in
      *":$d:"*) managed="$managed$d:" ;;
      *) case "$now" in *":$d:"*) ;; *) managed="$managed$d:" ;; esac ;;
    esac
  done
  cur=( $PATH )
  for d in ${cur[@]+"${cur[@]}"}; do
    [ -n "$d" ] || continue
    case "$old" in *":$d:"*) case "$want" in *":$d:"*) ;; *) continue ;; esac ;; esac
    if [ "$first" -eq 1 ]; then case "$want" in *":$d:"*) continue ;; esac; fi
    case "$keep" in *":$d:"*) continue ;; esac
    keep="$keep$d:"
  done
  if [ "$first" -eq 1 ]; then
    keep="$want${keep#:}"
  else
    cur=( ${want#:} )
    for d in ${cur[@]+"${cur[@]}"}; do
      case "$keep" in
        *":$d:"*) ;;
        *)
          if [ -z "$prev" ]; then
            keep=":$d$keep"
          else
            out=":"
            ks=( ${keep#:} )
            for e in ${ks[@]+"${ks[@]}"}; do
              out="$out$e:"
              [ "$e" = "$prev" ] && out="$out$d:"
            done
            keep="$out"
          fi ;;
      esac
      prev="$d"
    done
  fi
  keep="${keep#:}"
  managed="${managed#:}"
  PATH="${keep%:}"
  _WAYU_PATHS_MANAGED="${managed%:}"
  [ "$glob" = 0 ] || set +f
  export PATH _WAYU_PATHS_MANAGED
}
_wayu_paths_sync() {
  local s=$? l
  local m="$_WAYU_PATHS_FILE.regen-failed"
  if [ "${_WAYU_PATHS_REGEN-1}" = 1 ] && { [ "${_WAYU_TOML_FILE-}" -nt "$_WAYU_PATHS_FILE" ] || [ "${_WAYU_ENTRIES_FILE-}" -nt "$_WAYU_PATHS_FILE" ]; } &&
     { [ ! -e "$m" ] || ! [ "${_WAYU_TOML_FILE-}" -ot "$m" ] || ! [ "${_WAYU_ENTRIES_FILE-}" -ot "$m" ]; }; then
    WAYU_PROMPT_HOOK=1 command "${_WAYU_BIN:-wayu}" build </dev/null >/dev/null
    if [ "${_WAYU_TOML_FILE-}" -nt "$_WAYU_PATHS_FILE" ] || [ "${_WAYU_ENTRIES_FILE-}" -nt "$_WAYU_PATHS_FILE" ]; then
      { : >| "$m"; } 2>/dev/null || _WAYU_PATHS_REGEN=0
    fi
  fi
  { read -r l < "$_WAYU_PATHS_FILE"; } 2>/dev/null || return $s
  [ "$l" = "${_WAYU_PATHS_SIG-}" ] || . "$_WAYU_PATHS_FILE"
  return $s
}
case ";${PROMPT_COMMAND-};" in
  *";_wayu_paths_sync;"*) ;;
  *) PROMPT_COMMAND="_wayu_paths_sync${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
esac
`

// fish: same algorithm as the zsh/bash _wayu_paths_apply (see above); PATH
// is a list, so no ':' splitting. The first call moves the wanted dirs to the
// front in [paths] order, like `fish_add_path -gpm` (a dir already on PATH
// gets wayu's priority instead of keeping its old position). The sync runs
// on the fish_prompt event; event handlers leave $status alone.
WAYU_PATH_SYNC_FISH :: `function _wayu_paths_apply
    set -l first 0
    set -q _WAYU_PATHS_SIG; or set first 1
    set -g _WAYU_PATHS_SIG "# wayu-paths $argv[1]"
    set -l want
    set -l keep
    set -l managed
    set -l old (string split -n : -- "$_WAYU_PATHS_MANAGED")
    for d in $argv[2..-1]
        test -n "$d"; or continue
        string match -q -- '*:*' $d; and continue
        string match -q -- '*'\n'*' $d; and continue
        test -d $d; or continue
        contains -- $d $want; or set -a want $d
    end
    for d in $want
        if contains -- $d $old; or not contains -- $d $PATH
            set -a managed $d
        end
    end
    for d in $PATH
        contains -- $d $old; and not contains -- $d $want; and continue
        test $first = 1; and contains -- $d $want; and continue
        contains -- $d $keep; or set -a keep $d
    end
    if test $first = 1
        set keep $want $keep
    else
        set -l prev
        for d in $want
            if not contains -- $d $keep
                if test -z "$prev"
                    set keep $d $keep
                else
                    set -l i (contains -i -- $prev $keep)
                    set -l rest
                    test $i -lt (count $keep); and set rest $keep[(math $i + 1)..-1]
                    set keep $keep[1..$i] $d $rest
                end
            end
            set prev $d
        end
    end
    set -gx PATH $keep
    set -gx _WAYU_PATHS_MANAGED (string join : -- $managed)
end
function _wayu_paths_sync --on-event fish_prompt
    set -l m "$_WAYU_PATHS_FILE.regen-failed"
    if test "$_WAYU_PATHS_REGEN" != 0; and begin; test "$_WAYU_TOML_FILE" -nt "$_WAYU_PATHS_FILE"; or test "$_WAYU_ENTRIES_FILE" -nt "$_WAYU_PATHS_FILE"; end; and begin; not test -e "$m"; or not test "$_WAYU_TOML_FILE" -ot "$m"; or not test "$_WAYU_ENTRIES_FILE" -ot "$m"; end
        set -l bin wayu
        test -n "$_WAYU_BIN"; and set bin $_WAYU_BIN
        WAYU_PROMPT_HOOK=1 command $bin build </dev/null >/dev/null
        if begin; test "$_WAYU_TOML_FILE" -nt "$_WAYU_PATHS_FILE"; or test "$_WAYU_ENTRIES_FILE" -nt "$_WAYU_PATHS_FILE"; end
            true >"$m" 2>/dev/null; or set -g _WAYU_PATHS_REGEN 0
        end
    end
    test -f "$_WAYU_PATHS_FILE"; or return 0
    set -l l
    read -l l <"$_WAYU_PATHS_FILE"
    test "$l" = "$_WAYU_PATHS_SIG"; or source "$_WAYU_PATHS_FILE"
end
`

// fish evalcache: `<tool> <args> | source`, cached like zsh/bash. The
// signature is the resolved binary path + mtime (`path`, fish 3.5+; older
// fish runs the tool every start, uncached). Cache keys get a `fish__`
// prefix so they never collide with a zsh/bash cache of the same tool.
// No fork on a cache hit (`command -s`, `path` and `read` are builtins).
HELPER_EVALCACHE_FISH :: `function _wayu_evalcache
    set -l cmd $argv[1]
    set -l bin (command -s -- $cmd); or return 0
    if not builtin -q path
        command $argv 2>/dev/null | source
        return 0
    end
    set -l base $HOME/.cache
    test -n "$XDG_CACHE_HOME"; and set base $XDG_CACHE_HOME
    set -l key fish__(string replace -ra '[^A-Za-z0-9._-]' _ -- $cmd)
    set -q argv[2]; and set key $key"__"(string replace -ra '[^A-Za-z0-9._-]' _ -- "$argv[2..-1]")
    set key (string sub -l 200 -- $key)
    set -l cache_file $base/wayu/evalcache/$key
    set -l real (path resolve -- $bin)
    set -l sig (string replace -a \n '?' -- "# wayu-evalcache: $real "(path mtime -- $real))
    set -l line
    test -s $cache_file; and read -l line <$cache_file
    if test "$line" != "$sig"
        command mkdir -p -- $base/wayu/evalcache
        set -l out (command $argv 2>/dev/null; echo "wayu-status:$status")
        set -l tmp $cache_file.tmp.$fish_pid
        if test "$out[-1]" = wayu-status:0; and set -q out[2]; and printf '%s\n' $sig $out[1..-2] >$tmp
            command mv -f -- $tmp $cache_file
        else
            command rm -f -- $tmp
            test -s $cache_file; or return 1
        end
    end
    source $cache_file
end
`

// One piece of a [paths] value: literal text or a simple variable reference
// ($NAME / ${NAME}). Anything else (`${X:-y}`, `$(`, a bare `$`) is literal.
PathValueSegment :: struct {
	text:   string, // literal text, or the variable NAME
	is_var: bool,
}

// Split a [paths] value (after `~` → `$HOME`) into literal / variable
// segments. Segments slice `v`; the array uses `allocator`.
split_path_value :: proc(
	v: string,
	allocator := context.temp_allocator,
) -> [dynamic]PathValueSegment {
	segs := make([dynamic]PathValueSegment, allocator)
	lit_start := 0
	i := 0
	for i < len(v) {
		if v[i] != '$' {
			i += 1; continue
		}
		j := i + 1
		braced := j < len(v) && v[j] == '{'
		if braced {
			j += 1
		}
		name_start := j
		for j < len(v) {
			c := v[j]
			if !((c >= 'A' && c <= 'Z') ||
				   (c >= 'a' && c <= 'z') ||
				   (c >= '0' && c <= '9') ||
				   c == '_') {
				break
			}
			j += 1
		}
		name := v[name_start:j]
		ok := is_shell_var_name(name) && (!braced || (j < len(v) && v[j] == '}'))
		if !ok {
			i += 1; continue
		}
		if braced {
			j += 1
		}
		if i > lit_start {
			append(&segs, PathValueSegment{text = v[lit_start:i]})
		}
		append(&segs, PathValueSegment{text = name, is_var = true})
		i = j
		lit_start = j
	}
	if lit_start < len(v) {
		append(&segs, PathValueSegment{text = v[lit_start:]})
	}
	return segs
}

// zsh/bash word for a [paths] value, expanded by the SHELL at source time
// (so `$GOPATH/bin` uses the shell's GOPATH, including one exported from
// [env] earlier in core). Literal parts are single-quoted; each variable is
// "${NAME}". The word is wrapped in ${NAME:+...} per variable, so an unset
// or empty variable drops the entry instead of turning `$X/bin` into `/bin`.
path_value_shell_word :: proc(v: string, allocator := context.temp_allocator) -> string {
	segs := split_path_value(v)
	names := make([dynamic]string, context.temp_allocator)
	for s in segs {
		if s.is_var && !slice.contains(names[:], s.text) {
			append(&names, s.text)
		}
	}
	sb := strings.builder_make(allocator)
	for n in names {
		strings.write_string(&sb, "${")
		strings.write_string(&sb, n)
		strings.write_string(&sb, ":+")
	}
	for s in segs {
		if s.is_var {
			strings.write_string(&sb, `"${`)
			strings.write_string(&sb, s.text)
			strings.write_string(&sb, `}"`)
		} else {
			strings.write_string(&sb, shell_single_quote(s.text, context.temp_allocator))
		}
	}
	for _ in names {strings.write_byte(&sb, '}')}
	return strings.to_string(sb)
}

// fish counterpart of path_value_shell_word: literal parts via
// escape_fish_string, variables as "$NAME" (adjacent quoted strings
// concatenate). Returns the word and a `test -n "$A"; and ...` guard prefix
// ("" when the value has no variables).
path_value_fish_word :: proc(
	v: string,
	allocator := context.temp_allocator,
) -> (
	word: string,
	guard: string,
) {
	segs := split_path_value(v)
	w := strings.builder_make(allocator)
	g := strings.builder_make(allocator)
	seen := make([dynamic]string, context.temp_allocator)
	for s in segs {
		if !s.is_var {
			strings.write_string(&w, escape_fish_string(s.text, context.temp_allocator))
			continue
		}
		strings.write_string(&w, `"$`)
		strings.write_string(&w, s.text)
		strings.write_byte(&w, '"')
		if !slice.contains(seen[:], s.text) {
			append(&seen, s.text)
			fmt.sbprintf(&g, `test -n "$%s"; and `, s.text)
		}
	}
	return strings.to_string(w), strings.to_string(g)
}

// PATH entry dirs exactly as stored (leading `~` → `$HOME`), in ORDER
// (= PATH priority), without duplicates and without values containing ':'
// or newlines. Variables are NOT expanded and existence is NOT checked here:
// path_sync / core.fish expand them in the shell and skip missing dirs at
// runtime, so a dir created later (tool installed after `wayu build`) and
// vars the wayu process doesn't have (e.g. a GOPATH constant) still work.
read_path_values :: proc() -> [dynamic]string {
	store := entries_load()
	defer entries_store_destroy(&store)

	values := make([dynamic]string)
	for e in store.paths {
		if len(strings.trim_space(e.dir)) == 0 {
			continue
		}
		if !is_path_entry_safe(e.dir) {
			// stderr: keep stdout clean for callers that capture it.
			fmt.eprintfln("[wayu] PATH entry %s contains ':' or a newline - skipping", e.key)
			continue
		}
		v := expand_leading_tilde_to_home_var(e.dir)
		if slice.contains(values[:], v) {
			delete(v)
			continue
		}
		append(&values, v)
	}
	return values
}

// Absolute path of the running binary, embedded in core (the prompt hook's
// `wayu build`, the secrets loader): they run before or without the PATH
// that found wayu, so a bare `wayu` can fail (OKAMI-292). argv[0] with a
// '/' is made absolute; a bare name is looked up on $PATH like the shell
// did; else the OS executable path. Made absolute lexically, never
// symlink-resolved (filepath.abs is realpath): /opt/homebrew/bin/wayu must
// survive `brew upgrade` (the Cellar path it links to is removed).
// Temp-allocated; "" only when nothing works.
wayu_self_path :: proc() -> string {
	if len(os.args) > 0 && len(os.args[0]) > 0 {
		arg0 := os.args[0]
		if !strings.contains(arg0, "/") {
			arg0 = script_find_on_path(arg0)
		}
		if strings.has_prefix(arg0, "/") {
			clean, _ := filepath.clean(arg0, context.temp_allocator)
			return clean
		}
		if len(arg0) > 0 {
			if cwd, err := os.get_working_directory(context.temp_allocator); err == nil {
				joined, _ := filepath.join({cwd, arg0}, context.temp_allocator)
				return joined
			}
		}
	}
	if exe, err := os.get_executable_path(context.temp_allocator); err == nil {
		return exe
	}
	return ""
}

// [paths] values for path sync (see read_wayu_toml_path_values) and their
// signature: FNV-1a of the raw values, so an unchanged list never triggers a
// resync. Caller deletes each value and the array.
read_path_sync_values :: proc() -> (values: [dynamic]string, sig: u64) {
	values = read_path_values()
	script_path_prepend(&values) // <data>/bin first (`wayu script`)
	joined := strings.join(values[:], "\n", context.temp_allocator)
	sig = hash.fnv64a(transmute([]byte)joined)
	return
}

// `_wayu_paths_apply <sig> <word>...` + newline (values expanded by the
// shell, see path_value_shell_word). core.<ext> runs it at startup and
// path_sync.<ext> holds it for the prompt hook.
emit_path_apply_call :: proc(b: ^strings.Builder, values: []string, sig: u64) {
	fmt.sbprintf(b, "_wayu_paths_apply %x", sig)
	for v in values {
		fmt.sbprint(b, " ")
		fmt.sbprint(b, path_value_shell_word(v))
	}
	fmt.sbprintln(b)
}

// fish: fish has no `${X:+...}`, so each value is appended to a list behind
// its own `test -n "$VAR"` guard (path_value_fish_word), then applied.
emit_path_apply_call_fish :: proc(b: ^strings.Builder, values: []string, sig: u64) {
	fmt.sbprintln(b, "set -l _wayu_w")
	for v in values {
		word, guard := path_value_fish_word(v)
		fmt.sbprintfln(b, "%sset -a _wayu_w %s", guard, word)
	}
	fmt.sbprintfln(b, "_wayu_paths_apply %x $_wayu_w", sig)
}

// Write $data/path_sync.<ext>: line 1 is the signature (FNV-1a of the raw
// [paths] values, so an unchanged list never triggers a resync), line 2
// applies the list (values expanded by the shell, see
// path_value_shell_word). Returns the file path; the caller deletes it.
write_path_sync_file :: proc() -> (file: string) {
	values, sig := read_path_sync_values()
	defer {
		for v in values {delete(v)}
		delete(values)
	}
	file = fmt.aprintf("%s/path_sync.%s", wayu.data, get_shell_extension(wayu.shell))

	b: strings.Builder
	strings.builder_init(&b)
	defer strings.builder_destroy(&b)
	fmt.sbprintfln(&b, "# wayu-paths %x", sig)
	if wayu.shell == .FISH {
		emit_path_apply_call_fish(&b, values[:], sig)
	} else {
		emit_path_apply_call(&b, values[:], sig)
	}
	// Atomic replace: open shells read this file from a prompt hook, and a
	// half-written list would make them drop PATH entries.
	if write_file_atomic(file, transmute([]byte)strings.to_string(b)) != nil {
		print_warning("Failed to write %s", file)
	}
	return
}

// Export the WAYU_CONFIG_DIR / WAYU_DATA_DIR this core was generated with
// when they differ from the defaults (config ~/.config/wayu, data
// ${XDG_DATA_HOME:-~/.local/share}/wayu; see init_app_context). `wayu`
// commands typed in the shell, and the background `wayu build` of path
// sync, then act on the dirs this shell was set up from. Nothing is emitted
// for the default layout.
@(private = "file")
emit_dir_overrides :: proc(b: ^strings.Builder, fish: bool) {
	default_config := fmt.aprintf("%s/.config/wayu", wayu.home)
	defer delete(default_config)
	default_data := default_data_dir(wayu.home, context.temp_allocator)
	vars := [2][2]string {
		{"WAYU_CONFIG_DIR", wayu.config if wayu.config != default_config else ""},
		{"WAYU_DATA_DIR", wayu.data if wayu.data != default_data else ""},
	}
	header := false
	for v in vars {
		if len(v[1]) == 0 {
			continue
		}
		if !header {
			fmt.sbprintln(b, "# === wayu directories (non-default) ===")
			header = true
		}
		if fish {
			fmt.sbprintfln(
				b,
				"set -gx %s %s",
				v[0],
				escape_fish_string(v[1], context.temp_allocator),
			)
		} else {
			fmt.sbprintfln(
				b,
				"export %s=%s",
				v[0],
				shell_double_quote_literal(v[1], context.temp_allocator),
			)
		}
	}
	if header {
		fmt.sbprintln(b)
	}
}

// zsh/bash: write core.<ext> — the ONE generated file init.<ext> sources —
// and path_sync.<ext> (re-read by the live PATH sync prompt hook). An
// existing turbo.<ext> gets the same content (`wayu export --turbo`).
generate_core_init_v2 :: proc() {
	shell_ext := get_shell_extension(wayu.shell)
	sync_file := write_path_sync_file()
	delete(sync_file)

	content := build_core_content()
	defer delete(content)
	path := fmt.tprintf("%s/core.%s", wayu.data, shell_ext)
	write_init_file(path, content)
	zcompile_file(path)

	turbo := fmt.tprintf("%s/turbo.%s", wayu.data, shell_ext)
	if os.exists(turbo) {
		write_turbo_file(turbo, content)
	}
}

// core.<ext> for zsh/bash (OKAMI-284). Everything is precomputed at build
// time as straight-line code in a single (zcompiled) file; the dynamic parts
// — [tools] lazy loaders, the prompt, live PATH sync — are function
// definitions and hooks, not work done at startup. Each `# === name ===`
// line starts a section (`wayu build profile` times them one by one), so a
// section never opens a block that a later section closes.
//
// zsh and bash share the structure; every zsh-only construct (fpath,
// compinit, add-zsh-hook, prompt, `[[ -o login ]]`) is gated so core.bash
// stays valid bash. `mask` hides secret-looking [env] values (dry-run
// previews). Caller owns the result.
build_core_content :: proc(mask := false) -> string {
	is_zsh := wayu.shell == .ZSH
	shell_ext := get_shell_extension(wayu.shell)

	b := strings.builder_make()

	fmt.sbprintln(&b, get_shebang(wayu.shell))
	fmt.sbprintfln(
		&b,
		"# core.%s - generated by wayu from wayu.toml and entries.json (`wayu build`); do not edit.",
		shell_ext,
	)
	fmt.sbprintln(
		&b,
		"# Everything init sources, in one file; each `# === ... ===` line starts a section.",
	)
	fmt.sbprintln(&b)
	emit_dir_overrides(&b, false)

	// [env] first: [paths] values are expanded by the shell, so `$GOPATH/bin`
	// needs an [env] GOPATH exported before the PATH is applied.
	fmt.sbprintln(&b, "# === Environment ===")
	emit_env_exports(&b, mask = mask)
	fmt.sbprintln(&b)

	// PATH from [paths] (file order = priority). The startup apply is the same
	// call path_sync.<ext> makes, inlined (no extra file read); the prompt
	// hook re-sources path_sync.<ext> when its signature changes.
	fmt.sbprintln(&b, "# === PATH (live-synced at each prompt) ===")
	fmt.sbprint(&b, WAYU_PATH_SYNC_ZSH if is_zsh else WAYU_PATH_SYNC_BASH)
	sync_file := fmt.tprintf("%s/path_sync.%s", wayu.data, shell_ext)
	fmt.sbprintfln(
		&b,
		"_WAYU_PATHS_FILE=%s",
		shell_double_quote_literal(sync_file, context.temp_allocator),
	)
	if bin := wayu_self_path(); bin != "" {
		fmt.sbprintfln(&b, "_WAYU_BIN=%s", shell_double_quote_literal(bin, context.temp_allocator))
	}
	fmt.sbprintfln(
		&b,
		"_WAYU_TOML_FILE=%s",
		shell_double_quote_literal(
			fmt.tprintf("%s/wayu.toml", wayu.config),
			context.temp_allocator,
		),
	)
	fmt.sbprintfln(
		&b,
		"_WAYU_ENTRIES_FILE=%s",
		shell_double_quote_literal(entries_file_path(), context.temp_allocator),
	)
	{
		values, sig := read_path_sync_values()
		defer {
			for v in values {delete(v)}
			delete(values)
		}
		// _wayu_paths_apply leaves PATH deduplicated (wanted dirs first).
		emit_path_apply_call(&b, values[:], sig)
	}
	if is_zsh {
		// Keep PATH unique for the rest of the session too.
		fmt.sbprintln(&b, "typeset -U path PATH")
	}
	fmt.sbprintln(&b)
	// Encrypted constants: source the per-session cache (secrets_store.odin).
	// After the PATH apply (OKAMI-292): a cache miss runs wayu (absolute
	// path, see wayu_self_path), which may need the PATH entries' tools.
	emit_secrets_loader(&b, wayu.shell)
	emit_rc_watch(&b, wayu.shell) // optimize.odin

	startup := read_startup_settings()
	completions_dir := fmt.tprintf("%s/completions", wayu.data)
	fmt.sbprintln(&b, "# === Completions ===")
	if is_zsh {
		emit_zsh_completions(&b, completions_dir, startup)
	} else {
		// `wayu completions generate` writes wayu.bash; `completions add`
		// writes name.bash-completion (or keeps a given .bash name).
		q := shell_double_quote_literal(completions_dir, context.temp_allocator)
		emit_bash_glob_source(&b, q, {"*.bash-completion", "*.bash"})
	}
	fmt.sbprintln(&b)

	// Custom shell functions (user-authored, loaded immediately so they are
	// available in interactive and non-interactive shells alike).
	fmt.sbprintln(&b, "# === Functions ===")
	emit_functions_loader(&b)
	fmt.sbprintln(&b)

	// User configuration from config.{ext}
	config_user := fmt.tprintf("%s/config.%s", wayu.config, shell_ext)
	if os.exists(config_user) {
		if content, ok := safe_read_file(config_user); ok {
			defer delete(content)
			if len(content) > 0 {
				fmt.sbprintfln(&b, "# === User configuration (from config.%s) ===", shell_ext)
				fmt.sbprintln(&b, string(content))
				fmt.sbprintln(&b)
			}
		}
	}

	fmt.sbprintfln(&b, "# === Helpers (evalcache%s) ===", ", zsh-defer" if is_zsh else "")
	emit_helpers(&b)
	fmt.sbprintln(&b)

	tools := read_wayu_toml_tools()
	defer {
		for &t in tools {destroy_tool_entry(&t)}
		delete(tools)
	}

	// Eager tools (e.g. keybinding tools like atuin). Only `evalcache`-kind
	// tools may be eager; other recipes are always in the deferred section.
	eager_count := 0
	for t in tools {
		if t.eager && !t.login_only && tool_kind_is_evalcache(t.kind) {
			eager_count += 1
		}
	}
	if eager_count > 0 {
		fmt.sbprintln(&b, "# === Tools (eager - keybindings, immediate) ===")
		for t in tools {
			if !t.eager || t.login_only || !tool_kind_is_evalcache(t.kind) {
				continue
			}
			emit_evalcache_call(&b, t)
		}
		fmt.sbprintln(&b)
	}

	// Prompt: native wayu prompt is zsh-only (prompt escapes, zle, hooks),
	// opt-in via `[prompt] enabled = true` (see prompt_is_enabled), and set
	// up in interactive shells only (one section: the prompt code has no
	// `# ===` lines of its own).
	if is_zsh {
		toml_data, toml_ok := get_cached_toml_content()
		if toml_ok && prompt_is_enabled(toml_data) {
			fmt.sbprintln(&b, "# === Prompt (wayu native, interactive shells) ===")
			prompt_cfg := parse_full_prompt_config(toml_data)
			defer destroy_full_prompt_config(&prompt_cfg)
			base_prompt := generate_full_prompt(prompt_cfg)
			defer delete(base_prompt)

			interactive_cfg := parse_interactive_config(toml_data)
			interactive_cfg.contexts = &prompt_cfg
			interactive_code := generate_interactive_prompt(base_prompt, interactive_cfg)
			defer delete(interactive_code)

			fmt.sbprintln(&b, "if [[ -o interactive ]]; then")
			fmt.sbprint(&b, interactive_code)
			fmt.sbprintln(&b, "fi")
			fmt.sbprintln(&b)
		}
	}

	// Plugins. plugins.{ext} is the loader generated from plugins.json: only
	// enabled plugins load (no hard-coded zsh-autosuggestions /
	// zsh-syntax-highlighting fallback: it loaded disabled plugins, OKAMI-310).
	// zsh: interactive shells only (plugins are line-editor features;
	// OKAMI-375); `[settings] defer_plugins` loads them after the first
	// prompt is drawn (zsh-defer), as one function so the order holds.
	// `[settings] autosuggest` (built-in suggestions) is set up first: after
	// the prompt (its `bindkey -v`) and before the plugins, so
	// syntax-highlighting's redraw hook runs after the suggestion's. The
	// zsh-autosuggestions plugin is then not loaded: marked as loaded for
	// plugins.zsh's guard (`wayu doctor` warns while it is enabled).
	// `[settings] highlight` (built-in syntax highlighting) likewise goes
	// before the plugins and keeps zsh-syntax-highlighting /
	// fast-syntax-highlighting from loading (plugins.zsh's guard).
	if is_zsh && startup.autosuggest {
		fmt.sbprintln(&b, "# === Autosuggestions (wayu built-in, [settings] autosuggest) ===")
		emit_zsh_suggest(&b, startup.autosuggest_style)
		fmt.sbprintln(&b)
	}
	if is_zsh && startup.highlight {
		fmt.sbprintln(&b, "# === Syntax highlighting (wayu built-in, [settings] highlight) ===")
		emit_zsh_highlight(&b, startup.highlight_styles)
		fmt.sbprintln(&b)
	}
	fmt.sbprintln(&b, "# === Plugins ===")
	if is_zsh {
		plugins_dir := fmt.tprintf("%s/plugins", wayu.data)
		fmt.sbprintln(&b, "if [[ -o interactive ]]; then")
		if startup.autosuggest {
			fmt.sbprintln(
				&b,
				`[[ ":${_WAYU_PLUGINS_LOADED-}:" == *:zsh-autosuggestions:* ]] || _WAYU_PLUGINS_LOADED="${_WAYU_PLUGINS_LOADED-}:zsh-autosuggestions"`,
			)
		}
		if startup.highlight {
			hl_plugins := HIGHLIGHT_PLUGINS
			for name in hl_plugins {
				fmt.sbprintfln(
					&b,
					`[[ ":${{_WAYU_PLUGINS_LOADED-}}:" == *:%s:* ]] || _WAYU_PLUGINS_LOADED="${{_WAYU_PLUGINS_LOADED-}}:%s"`,
					name,
					name,
				)
			}
		}
		if startup.defer_plugins {
			fmt.sbprintln(&b, "function _wayu_plugins_load {")
		}
		emit_source_if_exists(&b, runtime_file("plugins"))
		emit_source_if_exists(&b, fmt.tprintf("%s/config.zsh", plugins_dir))
		if startup.defer_plugins {
			fmt.sbprintln(&b, "}")
			fmt.sbprintln(&b, "zsh-defer _wayu_plugins_load")
		}
		fmt.sbprintln(&b, "fi")
	} else {
		emit_source_if_exists(&b, runtime_file("plugins"))
	}
	fmt.sbprintln(&b)

	// Deferred tools: everything not handled as eager above (evalcache plus
	// the lazy recipes nvm, conda, lazy — wrappers that load on first use).
	deferred_count := 0
	for t in tools {
		if t.login_only || (t.eager && tool_kind_is_evalcache(t.kind)) {
			continue
		}
		deferred_count += 1
	}
	if deferred_count > 0 {
		fmt.sbprintln(&b, "# === Tools (deferred) ===")
		for t in tools {
			if t.login_only || (t.eager && tool_kind_is_evalcache(t.kind)) {
				continue
			}
			emit_tool_recipe(&b, t)
		}
		fmt.sbprintln(&b)
	}

	// User escape hatches, tools first then extra (fish follows the same
	// order). Sourced in every shell, not just login ones, so Ghostty /
	// Zellij / tmux panes also pick up user loaders.
	fmt.sbprintfln(&b, "# === User tools.%s (escape hatch for unrecognised tools) ===", shell_ext)
	emit_source_if_exists(&b, fmt.tprintf("%s/tools.%s", wayu.config, shell_ext))
	fmt.sbprintln(&b)
	fmt.sbprintln(&b, "# === Extra config ===")
	emit_source_if_exists(&b, fmt.tprintf("%s/extra.%s", wayu.config, shell_ext))
	fmt.sbprintln(&b)

	// Login-shell-only tools (login_only = true).
	login_count := 0
	for t in tools {
		if t.login_only {
			login_count += 1
		}
	}
	if login_count > 0 {
		fmt.sbprintln(&b, "# === Login shell only ===")
		fmt.sbprintln(&b, "if [[ -o login ]]; then" if is_zsh else "if shopt -q login_shell; then")
		// `:` keeps the block valid when every entry was skipped (comments only).
		fmt.sbprintln(&b, "  :")
		for t in tools {
			if t.login_only {
				emit_tool_recipe(&b, t)
			}
		}
		fmt.sbprintln(&b, "fi")
		fmt.sbprintln(&b)
	}

	// Generators moved from the rc file by `wayu optimize` run where those
	// lines ran: after everything else wayu sets up.
	emit_generators(&b, wayu.shell)

	// Aliases last (OKAMI-224): zsh and bash expand aliases while parsing, so
	// an [aliases] entry named like a wrapper wayu defines earlier (npm,
	// conda, a lazy hook command) would break that definition. Defined here
	// they only affect what the user types.
	fmt.sbprintln(&b, "# === Aliases ===")
	emit_alias_definitions(&b)
	fmt.sbprintln(&b)
	if is_zsh {
		// Last, so nothing in core runs under the trap (OKAMI-318).
		fmt.sbprintln(&b, "# === PATH order for login -c runs ===")
		fmt.sbprint(&b, WAYU_PATH_LOGIN_RESTORE_ZSH)
		fmt.sbprintln(&b)
	}

	return strings.to_string(b)
}

// [settings] keys that shape the generated zsh startup (OKAMI-372/375).
StartupSettings :: struct {
	compinit_guard:    bool, // later `compinit` calls only register new fpath dirs
	defer_plugins:     bool, // plugins load after the first prompt (zsh-defer)
	lazy_compinit:     bool, // compinit on the first completion attempt
	autosuggest:       bool, // built-in history autosuggestions (OKAMI-376)
	autosuggest_style: string, // region_highlight spec of the suggestion (temp-allocated)
	highlight:         bool, // built-in syntax highlighting (OKAMI-377)
	highlight_styles:  [HIGHLIGHT_STYLE_COUNT]string, // see HIGHLIGHT_STYLES (temp-allocated)
}

AUTOSUGGEST_DEFAULT_STYLE :: "fg=8"

// Read StartupSettings from wayu.toml (cached content); a missing key or a
// non-boolean value keeps the default.
read_startup_settings :: proc() -> StartupSettings {
	s := StartupSettings {
		compinit_guard    = true,
		autosuggest_style = AUTOSUGGEST_DEFAULT_STYLE,
	}
	styles := HIGHLIGHT_STYLES
	for st, i in styles {s.highlight_styles[i] = st.default}
	content, ok := get_cached_toml_content()
	if !ok {
		return s
	}
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return s
	}
	defer virtual.arena_destroy(&arena)
	doc, _ := toml_doc_parse_alloc(content, virtual.arena_allocator(&arena))
	keys := [?]struct {
		name:  string,
		field: ^bool,
	} {
		{"settings.compinit_guard", &s.compinit_guard},
		{"settings.defer_plugins", &s.defer_plugins},
		{"settings.lazy_compinit", &s.lazy_compinit},
		{"settings.autosuggest", &s.autosuggest},
		{"settings.highlight", &s.highlight},
	}
	for k in keys {
		if v := get_toml_value(&doc, k.name); v != nil && v.type == .BOOLEAN {
			k.field^ = v.bool_val
		}
	}
	if v := get_toml_value(&doc, "settings.autosuggest_style");
	   v != nil && v.type == .STRING && autosuggest_style_valid(v.str_val) {
		s.autosuggest_style = strings.clone(v.str_val, context.temp_allocator)
	}
	s.highlight_styles = read_highlight_styles(&doc)
	return s
}

// A usable `[settings] autosuggest_style`: a short region_highlight spec
// (`fg=8`, `fg=244,underline`) on one line.
autosuggest_style_valid :: proc(style: string) -> bool {
	if len(style) == 0 || len(style) > 64 {
		return false
	}
	for c in transmute([]byte)style {
		if c < 0x20 || c == 0x7f {
			return false
		}
	}
	return true
}

// `[settings] autosuggest` (OKAMI-376): fish-like suggestions from history,
// built into core.zsh. Interactive zsh >= 5.3 with zle only; nothing forks.
//
// The zsh-autosuggestions plugin wraps every zle widget at the first prompt
// (and by default re-wraps them before every prompt). Here the suggestion
// is computed in a zle-line-pre-redraw hook (add-zle-hook-widget, which
// zsh-syntax-highlighting >= 0.8 shares): the newest history entry that
// starts with $BUFFER (`(b)`: glob chars typed are literal), shown in
// POSTDISPLAY and highlighted by a region_highlight entry (removed by its
// exact text, with `memo=` on zsh >= 5.9 so other highlighters keep it).
// Only the accept widgets (forward-char, end-of-line, vi-forward-char,
// vi-end-of-line, vi-add-eol: take the whole suggestion) and the
// partial-accept ones (forward-word & co.: run on BUFFER+suggestion, keep
// what ends up left of the cursor) are wrapped, chaining to the widget that
// was there before. History/search widgets clear the suggestion (the line
// came from history already); zle-line-finish clears it so an accepted line
// never keeps it. `[settings] autosuggestions_accept_keys` are bound to
// wayu-suggest-accept (emacs + viins).
emit_zsh_suggest :: proc(b: ^strings.Builder, style: string) {
	keys := plugin_accept_keys_from_toml()
	defer {
		for k in keys {delete(k)}
		delete(keys)
	}
	binds := strings.builder_make(context.temp_allocator)
	for k in keys {
		// Same filter as the plugin's config.zsh: key sequences, not names.
		if len(k) == 0 || (!strings.has_prefix(k, "^") && !strings.contains(k, "[")) {
			continue
		}
		qk := shell_quote(k, .ZSH) // temp-allocated
		fmt.sbprintfln(
			&binds,
			"    bindkey -M emacs %s wayu-suggest-accept; bindkey -M viins %s wayu-suggest-accept",
			qk,
			qk,
		)
	}
	code, _ := strings.replace_all(
		ZSH_SUGGEST,
		"@STYLE@",
		shell_double_quote_literal(style, context.temp_allocator),
		context.temp_allocator,
	)
	code, _ = strings.replace_all(
		code,
		"@BINDS@\n",
		strings.to_string(binds),
		context.temp_allocator,
	)
	fmt.sbprint(b, code)
}

ZSH_SUGGEST :: `if [[ -o interactive && -o zle ]]; then
  function _wayu_suggest_redraw {
    emulate -L zsh
    local -i end=$#BUFFER
    [[ $KEYMAP == vicmd ]] && (( end-- ))
    if (( ! $#BUFFER || CURSOR != end || PENDING )) || [[ $LASTWIDGET == (*history*|*search*) ]]; then
      POSTDISPLAY=
      _wayu_suggest_buf=
    elif [[ $BUFFER != "$_wayu_suggest_buf" ]]; then
      # Typing on from the last lookup: its entry (or no match) still holds.
      if [[ -z $_wayu_suggest_buf || $BUFFER != "$_wayu_suggest_buf"* ||
            ( -n $_wayu_suggest_full && $_wayu_suggest_full != "$BUFFER"* ) ]]; then
        _wayu_suggest_full=${history[(r)${(b)BUFFER}*]}
        # No history match on the first word: complete a command name from
        # PATH (shortest, then alphabetical).
        if [[ -z $_wayu_suggest_full && $BUFFER != *[^[:alnum:]_.+-]* ]]; then
          local c
          for c in ${(ko)commands[(I)${(b)BUFFER}?*]}; do
            (( ! $#_wayu_suggest_full || $#c < $#_wayu_suggest_full )) && _wayu_suggest_full=$c
          done
        fi
      fi
      _wayu_suggest_buf=$BUFFER
      POSTDISPLAY=${_wayu_suggest_full[$#BUFFER+1,-1]}
    fi
    _wayu_suggest_paint
    return 0
  }
  function _wayu_suggest_paint {
    (( $#_wayu_suggest_hl )) && region_highlight=( "${(@)region_highlight:#(${_wayu_suggest_hl}|*memo=wayu-suggest)}" )
    if (( $#POSTDISPLAY )); then
      _wayu_suggest_hl="$#BUFFER $(( $#BUFFER + $#POSTDISPLAY )) $_wayu_suggest_style"
      region_highlight+=( "$_wayu_suggest_hl" )
    else
      _wayu_suggest_hl=
    fi
    return 0
  }
  function _wayu_suggest_finish {
    emulate -L zsh
    POSTDISPLAY=
    _wayu_suggest_buf=
    _wayu_suggest_paint
  }
  # $1: the wrapped widget (empty for wayu-suggest-accept), then its args.
  function _wayu_suggest_accept {
    emulate -L zsh
    local w=$1
    shift
    local -i end=$#BUFFER ret=0
    [[ $KEYMAP == vicmd ]] && (( end-- ))
    if (( ! $#POSTDISPLAY || CURSOR != end )); then
      [[ -z $w ]] || zle _wayu_suggest_orig_$w -- "$@"
      return
    fi
    BUFFER+=$POSTDISPLAY
    POSTDISPLAY=
    _wayu_suggest_buf=$BUFFER
    if [[ -n $w ]]; then
      zle _wayu_suggest_orig_$w -- "$@"
      ret=$?
    fi
    if [[ $KEYMAP == vicmd ]]; then CURSOR=$(( $#BUFFER - 1 )); else CURSOR=$#BUFFER; fi
    return ret
  }
  function _wayu_suggest_partial {
    emulate -L zsh
    local w=$1
    shift
    if (( ! $#POSTDISPLAY )); then
      zle _wayu_suggest_orig_$w -- "$@"
      return
    fi
    local orig=$BUFFER post=$POSTDISPLAY
    local -i ret loc
    BUFFER+=$POSTDISPLAY
    POSTDISPLAY=
    zle _wayu_suggest_orig_$w -- "$@"
    ret=$?
    loc=$CURSOR
    [[ $KEYMAP == vicmd ]] && (( loc++ ))
    if (( loc > $#orig )); then
      POSTDISPLAY=${BUFFER[loc+1,-1]}
      BUFFER=${BUFFER[1,loc]}
    else
      BUFFER=$orig
      POSTDISPLAY=$post
    fi
    _wayu_suggest_buf=$BUFFER
    return ret
  }
  function _wayu_suggest_key { _wayu_suggest_accept "" "$@"; }
  () {
    emulate -L zsh
    [[ $ZSH_VERSION == (5.<3->|<6->.)* ]] || return 0
    zmodload zsh/parameter zsh/zleparameter 2>/dev/null || return 0
    typeset -g _wayu_suggest_style=@STYLE@ _wayu_suggest_hl= _wayu_suggest_buf= _wayu_suggest_full=
    [[ $ZSH_VERSION == (5.<9->|<6->.)* ]] && _wayu_suggest_style+=", memo=wayu-suggest"
    (( ${+widgets[_wayu_suggest_redraw]} )) && return 0
    local w fn
    for fn w in accept forward-char accept end-of-line accept vi-forward-char accept vi-end-of-line \
                accept vi-add-eol partial forward-word partial emacs-forward-word partial vi-forward-word \
                partial vi-forward-word-end partial vi-forward-blank-word partial vi-forward-blank-word-end \
                partial vi-find-next-char partial vi-find-next-char-skip; do
      [[ ${widgets[$w]-} == user:_wayu_suggest_* ]] && continue
      zle -A $w _wayu_suggest_orig_$w
      functions[_wayu_suggest_$w]="_wayu_suggest_$fn $w \"\$@\""
      zle -N $w _wayu_suggest_$w
    done
    zle -N wayu-suggest-accept _wayu_suggest_key
    zle -N _wayu_suggest_redraw
    zle -N _wayu_suggest_finish
    autoload -Uz add-zle-hook-widget
    add-zle-hook-widget zle-line-pre-redraw _wayu_suggest_redraw
    add-zle-hook-widget zle-line-finish _wayu_suggest_finish
@BINDS@
  }
fi
`

// zsh completion setup: wayu's completions dir on fpath (once: re-sourcing
// core doesn't add it again), then compinit — in interactive shells only
// (completion is a line-editor feature; compinit is most of the cost of a
// non-interactive `source init.zsh`). Elsewhere a no-op `compdef` keeps
// plugins/tools that call it quiet.
//
// _wayu_compinit runs `compinit -C` on a cached dump. -C never scans fpath,
// so the dump is rebuilt (`-u`: no interactive compaudit prompt, as -C never
// audited) when its signature changed: the file listing of wayu's
// completions dir (a glob, no fork; whole-second mtimes missed a completion
// added in the same second as the dump, OKAMI-283) + every fpath dir with
// its mtime (zstat, one call), so completions brew/the system/a plugin add
// to any fpath dir are picked up too. The signature of the last rebuild is
// kept in $dump.wayu. A zcompiled dump loads ~40% faster, so it is compiled
// (in the background, temp file + rename) when missing or older than the
// dump, and installed only if the dump did not change while compiling.
//
// compinit guard (`[settings] compinit_guard`, default on): installers append
// `autoload -Uz compinit && compinit` to .zshrc, which redoes the whole
// completion setup (and with -C still misses the dirs they just put on
// fpath). After wayu's compinit, `compinit` is a function that only
// registers the `#compdef` / `#autoload` files of fpath dirs added since
// (as compinit itself would, first dir wins); its flags are accepted and
// ignored. `autoload -Uz compinit` of a defined function is a no-op in zsh,
// so the installer line can't replace it. The same scan runs once at the
// first prompt, for dirs added to fpath without a compinit call.
//
// lazy_compinit: the completion widgets (Tab etc.) are wrappers that run the
// setup above on first use and then re-run the widget (compinit replaces
// them with the real completion widgets); `compdef` calls made before that
// are queued and replayed.
@(private = "file")
emit_zsh_completions :: proc(b: ^strings.Builder, completions_dir: string, s: StartupSettings) {
	q := shell_double_quote_literal(completions_dir, context.temp_allocator)
	fmt.sbprintfln(
		b,
		`() {{ emulate -L zsh; (( ${{fpath[(Ie)$1]}} )) || fpath=( "$1" "${{fpath[@]}}" ) }} %s`,
		q,
	)
	// entries.json `fpath` (wayu optimize / completions fpath), before compinit.
	emit_managed_fpath(b)
	fmt.sbprintln(b, `if [[ -o interactive ]]; then`)
	code, _ := strings.replace_all(ZSH_COMPINIT, "@COMPLETIONS_DIR@", q, context.temp_allocator)
	fmt.sbprint(b, code)
	if s.compinit_guard {
		fmt.sbprint(b, ZSH_COMPINIT_GUARD)
	}
	if s.lazy_compinit {
		fmt.sbprint(b, ZSH_COMPINIT_LAZY)
		if !s.compinit_guard {
			// No guard: an early `compinit` call does the real setup now.
			fmt.sbprintln(
				b,
				`  if (( ! ${+_wayu_comp_fpath} )); then function compinit { _wayu_compinit_now; }; fi`,
			)
		}
	} else {
		fmt.sbprintln(b, `  _wayu_compinit`)
	}
	fmt.sbprintln(b, `else`)
	fmt.sbprintln(b, `  (( ${+functions[compdef]} )) || compdef() { return 0; }`)
	fmt.sbprintln(b, `fi`)
}

ZSH_COMPINIT :: `  function _wayu_compinit {
    emulate -L zsh
    if (( ${+_wayu_comp_fpath} )); then
      _wayu_compinit_scan
      return 0
    fi
    local dump="${ZDOTDIR:-$HOME}/.zcompdump" seen="" sig
    local -a comps=( @COMPLETIONS_DIR@/*(N:t) ) mt
    zmodload -F zsh/stat b:zstat 2>/dev/null
    zstat -A mt +mtime -- ${^fpath}(N/) 2>/dev/null
    sig="${(j:/:)comps} ${(j: :)fpath} ${(j: :)mt}"
    sig=${sig//$'\n'/?}
    { IFS= read -r seen < "$dump.wayu" } 2>/dev/null
    (( ${+functions[compinit]} )) && unfunction compinit
    autoload -Uz compinit
    if [[ ! -s $dump || "$seen" != "$sig" ]]; then
      command rm -f -- "$dump" "$dump.zwc"
      compinit -u -d "$dump"
      { print -r -- "$sig" >| "$dump.wayu" } 2>/dev/null
    else
      compinit -C -d "$dump"
    fi
    typeset -ga _wayu_comp_fpath=( "${fpath[@]}" )
    (( ${+functions[_wayu_compinit_guard]} )) && _wayu_compinit_guard
    if [[ -s $dump && -w ${dump:h} && ( ! -s $dump.zwc || $dump -nt $dump.zwc ) ]]; then
      {
        zmodload -F zsh/stat b:zstat || exit
        local -a s1 s2
        zstat -A s1 -- "$dump" || exit
        if zcompile -R -- "$dump.$$.zwc" "$dump" && zstat -A s2 -- "$dump" && [[ "${s1[1,2]} ${s1[8]} ${s1[10,11]}" == "${s2[1,2]} ${s2[8]} ${s2[10,11]}" ]]; then
          command mv -f -- "$dump.$$.zwc" "$dump.zwc"
          # A rebuild between the check and the mv: zsh would load this stale
          # .zwc (it wins when not older, whole seconds), so drop it.
          zstat -A s2 -- "$dump" && [[ "${s1[1,2]} ${s1[8]} ${s1[10,11]}" == "${s2[1,2]} ${s2[8]} ${s2[10,11]}" ]] || command rm -f -- "$dump.zwc"
        else
          command rm -f -- "$dump.$$.zwc"
        fi
      } >/dev/null 2>&1 &!
    fi
  }
  # Register the completions of fpath dirs added since _wayu_compinit.
  function _wayu_compinit_scan {
    emulate -L zsh -o extended_glob
    (( ${+_wayu_comp_fpath} && ${+functions[compdef]} )) || return 0
    local d f n
    local -a l
    for d in "${fpath[@]}"; do
      [[ $d == . ]] && continue
      (( ${_wayu_comp_fpath[(Ie)$d]} )) && continue
      _wayu_comp_fpath+=( "$d" )
      for f in $d/^([^_]*|*~|*.zwc)(N); do
        n=${f:t}
        IFS=$' \t' read -rA l < $f || continue
        case ${l[1]-} in
          ('#compdef')
            shift l
            if [[ ${l[1]-} == -[pPkK](n|) ]]; then
              compdef ${l[1]}na $n "${(@)l[2,-1]}"
            else
              compdef -na $n "${(@)l}"
            fi ;;
          ('#autoload')
            shift l
            autoload -rUz "${(@)l}" $n ;;
        esac
      done
    done
    return 0
  }
`

ZSH_COMPINIT_GUARD :: `  # compinit guard ([settings] compinit_guard): see init_generator.odin.
  function _wayu_compinit_guard {
    function compinit { _wayu_compinit_scan; }
  }
  function _wayu_compinit_first_prompt {
    local s=$?
    _wayu_compinit_scan
    add-zsh-hook -d precmd _wayu_compinit_first_prompt
    return $s
  }
  autoload -Uz add-zsh-hook
  add-zsh-hook precmd _wayu_compinit_first_prompt
`

ZSH_COMPINIT_LAZY :: `  # lazy_compinit ([settings]): completion set up on the first completion.
  if (( ! ${+_wayu_comp_fpath} )); then
    typeset -ga _wayu_compdef_queue
    function compdef { _wayu_compdef_queue+=( "${(j: :)${(@q)@}}" ); }
    if (( ${+functions[_wayu_compinit_guard]} )); then
      function compinit { return 0; }
    fi
    () {
      local w
      for w in complete-word delete-char-or-list expand-or-complete expand-or-complete-prefix \
               list-choices menu-complete menu-expand-or-complete reverse-menu-complete; do
        zle -N $w _wayu_compinit_lazy
      done
    } 2>/dev/null
  fi
  function _wayu_compinit_now {
    (( ${+_wayu_compdef_queue} )) || return 0
    local -a q=( "${_wayu_compdef_queue[@]}" )
    local c w
    unset _wayu_compdef_queue
    unfunction compdef 2>/dev/null
    for w in ${(k)widgets[(R)user:_wayu_compinit_lazy]}; do zle -A .$w $w; done
    _wayu_compinit
    for c in "${q[@]}"; do eval "compdef $c"; done
  }
  function _wayu_compinit_lazy {
    _wayu_compinit_now
    zle "$WIDGET" -- "$@"
  }
`

// evalcache. The cache key includes the sanitised args, so `zoxide init zsh`
// and `zoxide init zsh --cmd cd` don't share (and serve) a stale cache when
// args change in wayu.toml. The first line of a cache file records the
// binary it came from; the cache is regenerated when that binary changes.
// Neither shell forks at startup on a cache hit (no `$(command -v ...)`).
//
// zsh: signature = resolved path + size + mtime + inode (zsh/stat zstat),
// so a replaced binary with a preserved/fixed mtime (Nix store paths have
// mtime 1, tarballs keep build mtimes) or a moved symlink target is
// noticed. `wayu build clean` drops every cache (for output that depends
// on config or environment).
HELPER_EVALCACHE_ZSH :: `# ============================================================================
# EVALCACHE - Cache eval output, regenerate if the binary changed or args differ
# ============================================================================
_wayu_evalcache() {
  local cmd="$1" d bin_path=""
  shift
  # PATH search by hand: the first ${commands[...]} lookup hashes every PATH
  # dir (~2ms at startup).
  for d in "${path[@]}"; do
    [[ -f $d/$cmd && -x $d/$cmd ]] && { bin_path=$d/$cmd; break }
  done

  # Skip silently if the tool isn't installed
  [[ -n "$bin_path" && -x "$bin_path" ]] || return 0

  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/wayu/evalcache"
  local key="${cmd//[^A-Za-z0-9._-]/_}"
  if (( $# )); then
    local args="$*"
    key="${key}__${args//[^A-Za-z0-9._-]/_}"
  fi
  key="${key:0:200}"
  local cache_file="$cache_dir/$key"

  local real="${bin_path:A}" sig line=""
  local -A st
  zmodload -F zsh/stat b:zstat 2>/dev/null
  if zstat -H st -- "$real" 2>/dev/null; then
    sig="$real ${st[size]} ${st[mtime]} ${st[inode]}"
  else
    sig="$real"
    [[ "$real" -nt "$cache_file" ]] && sig="$real (newer)"
  fi
  sig="# wayu-evalcache: ${sig//$'\n'/?}"
  [[ -s "$cache_file" ]] && IFS= builtin read -r line < "$cache_file"

  if [[ "$line" != "$sig" ]]; then
    [[ -d "$cache_dir" ]] || command mkdir -p -- "$cache_dir"
    local out tmp_file="${cache_file}.tmp.$$"
    if out="$(command "$cmd" "$@" 2>/dev/null)" && [[ -n "$out" ]] &&
       builtin print -r -- "$sig"$'\n'"$out" > "$tmp_file"; then
      command mv -f -- "$tmp_file" "$cache_file"
    else
      # Failed or empty output - drop the tmpfile, leave any prior good cache alone
      command rm -f -- "$tmp_file"
      [[ -s "$cache_file" ]] || return 1
    fi
  fi

  source "$cache_file"
}
`

// bash has no stat builtin. Lookup goes through the hash table (BASH_CMDS,
// bash 4+) or, on bash 3.2, a PATH walk in the shell (no `$(type -P)` fork
// per tool, OKAMI-349). Every statement is `set -e` safe: a missing tool or a
// failed cache write never aborts a shell sourcing core with errexit on
// (OKAMI-315). The cache file gets the binary's
// mtime (`touch -r`) and must still match it exactly (`-nt` / `-ot` both
// false), and `<cache>.bin` pins the binary: a hard link to its resolved
// path (same inode), or a symlink to it when a hard link isn't possible
// (other filesystem, Linux protected_hardlinks). When the binary was
// replaced, the PATH entry resolves elsewhere (a new Nix store path) or the
// old target is gone, `-ef` fails and the cache is rebuilt.
HELPER_EVALCACHE_BASH :: `# ============================================================================
# EVALCACHE - Cache eval output, regenerate if the binary changed or args differ
# ============================================================================
_wayu_evalcache() {
  local cmd="$1"
  shift
  local bin_path="" d p
  if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ] && [[ $- == *h* ]]; then
    hash "$cmd" 2>/dev/null && bin_path="${BASH_CMDS[$cmd]-}"
  else
    p="${PATH-}:"
    while [ -n "$p" ]; do
      d=${p%%:*}
      p=${p#*:}
      if [ -n "$d" ] && [ -f "$d/$cmd" ] && [ -x "$d/$cmd" ]; then
        bin_path=$d/$cmd
        break
      fi
    done
  fi

  # Skip silently if the tool isn't installed
  [ -n "$bin_path" ] && [ -x "$bin_path" ] || return 0

  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/wayu/evalcache"
  local key="${cmd//[^A-Za-z0-9._-]/_}"
  if [ "$#" -gt 0 ]; then
    local args="$*"
    key="${key}__${args//[^A-Za-z0-9._-]/_}"
  fi
  key="${key:0:200}"
  local cache_file="$cache_dir/$key"
  local sig="# wayu-evalcache: ${bin_path//$'\n'/?}" line=""
  [ -s "$cache_file" ] && IFS= builtin read -r line < "$cache_file" || :

  if [ "$line" != "$sig" ] || [ "$bin_path" -nt "$cache_file" ] || [ "$bin_path" -ot "$cache_file" ] ||
     ! [ "$bin_path" -ef "$cache_file.bin" ]; then
    [ -d "$cache_dir" ] || command mkdir -p -- "$cache_dir" || :
    local out real tmp_file="${cache_file}.tmp.$$"
    if out="$(command "$cmd" "$@" 2>/dev/null)" && [ -n "$out" ] &&
       builtin printf '%s\n%s\n' "$sig" "$out" > "$tmp_file" &&
       command touch -r "$bin_path" -- "$tmp_file"; then
      real="$(command realpath -- "$bin_path" 2>/dev/null || command readlink -f -- "$bin_path" 2>/dev/null)" || real=
      real="${real:-$bin_path}"
      command ln -f -- "$real" "$cache_file.bin" 2>/dev/null || command ln -sfn -- "$real" "$cache_file.bin" || :
      command mv -f -- "$tmp_file" "$cache_file" || :
    else
      # Failed or empty output - drop the tmpfile, leave any prior good cache
      # alone (status 0: a failing tool must not abort a set -e shell)
      command rm -f -- "$tmp_file"
      [ -s "$cache_file" ] || return 0
    fi
  fi

  source "$cache_file"
}
`

// zsh-only helpers: built-in zsh-defer (interactive shells; a no-op
// elsewhere, where nothing ever drained the queue). The queue drains one
// command per idle moment of the line editor once the prompt is drawn: a
// `zle -F` handler on a /dev/null fd (always readable) runs as soon as zle
// waits for input — no fork, no signal (it used a precmd hook, which runs
// before the prompt is drawn, plus `sleep 0.1 && kill -USR1` subshells, and
// owned TRAPUSR1; OKAMI-375).
HELPER_ZSH_DEFER :: `
# ============================================================================
# ZSH-DEFER BUILT-IN - Implementation without external plugin
# Defers execution until the prompt is drawn and the line editor is idle
# ============================================================================
if [[ -o interactive ]]; then
  # Deferred command queue
  (( ${+_wayu_defer_queue} )) || typeset -ga _wayu_defer_queue
  typeset -g _wayu_defer_fd="${_wayu_defer_fd-}"

  function zsh-defer {
    local delay=0
    while [[ "$1" == -* ]]; do
      case "$1" in
        -t|--time) delay="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    local cmd="$*"
    [[ -n "$cmd" ]] || return 0
    _wayu_defer_queue+=("$cmd:$delay")
    _wayu_defer_arm
    return 0
  }

  # Process one deferred command
  function _wayu_defer_process_one {
    (( ${#_wayu_defer_queue} )) || return 0
    local item="${_wayu_defer_queue[@]:0:1}"  # first item, with or without KSH_ARRAYS
    local cmd="${item%:*}"
    local delay="${item##*:}"
    shift _wayu_defer_queue
    if [[ "$delay" != "0" && -n "$delay" ]]; then
      (command sleep "$delay" && eval "$cmd") &!
    else
      eval "$cmd"
    fi
    return 0
  }

  function _wayu_defer_arm {
    [[ -z $_wayu_defer_fd ]] || return 0
    {
      exec {_wayu_defer_fd}</dev/null &&
        zle -N _wayu_defer_resume &&
        zle -F -w $_wayu_defer_fd _wayu_defer_resume
    } 2>/dev/null || _wayu_defer_fd=""
    return 0
  }

  # zle -F widget: run one queued command, then wait for the next idle moment.
  function _wayu_defer_resume {
    zle -F $_wayu_defer_fd 2>/dev/null
    exec {_wayu_defer_fd}<&-
    _wayu_defer_fd=""
    _wayu_defer_process_one
    (( ${#_wayu_defer_queue} )) && _wayu_defer_arm
    zle reset-prompt 2>/dev/null
    zle -R 2>/dev/null
    return 0
  }
  (( ${#_wayu_defer_queue} )) && _wayu_defer_arm
else
  function zsh-defer { return 0; }
fi

# ============================================================================
# WAYU COMPILE - Compile init files to bytecode (manual command)
# ============================================================================
wayu_compile() {
  local f d=@WAYU_DATA_DIR@
  echo "Compiling init files to bytecode..."
  for f in core plugins turbo; do
    [[ -f "$d/$f.zsh" ]] || continue
    zcompile "$d/$f.zsh" 2>/dev/null && echo "✓ $f.zsh"
  done
  echo "Done. Loading 2-3x faster."
}
`

// Support functions (evalcache; zsh additionally gets zsh-defer and
// wayu_compile), emitted inline in core.<ext> (they were helpers.<ext>).
@(private = "file")
emit_helpers :: proc(b: ^strings.Builder) {
	if wayu.shell == .ZSH {
		fmt.sbprint(b, HELPER_EVALCACHE_ZSH)
		// wayu_compile works on the data dir this file was generated for.
		data_q := shell_double_quote_literal(wayu.data, context.temp_allocator)
		defer_code, _ := strings.replace_all(
			HELPER_ZSH_DEFER,
			"@WAYU_DATA_DIR@",
			data_q,
			context.temp_allocator,
		)
		fmt.sbprint(b, defer_code)
	} else {
		fmt.sbprint(b, HELPER_EVALCACHE_BASH)
	}
}

// ============================================================================
// Tool init entries from wayu.toml [tools]
// ============================================================================
//
//   [tools]
//   zoxide = { kind = "evalcache", args = "init zsh" }
//   atuin  = { kind = "evalcache", args = "init zsh --disable-up-arrow", eager = true }
//   nvm    = { kind = "nvm" }
//   conda  = { kind = "conda" }
//   sdk    = { kind = "lazy", init_script = "$HOME/.sdkman/bin/sdkman-init.sh", hook_commands = ["sdk"] }
//
// Recognised kinds:
//   evalcache  default; runs `<name> <args>`, caches output, sources cache
//   nvm        full lazy NVM wrapper (PATH-only default + on-demand load)
//   conda      lazy conda wrapper (load on first conda/mamba invocation)
//   lazy       generic - wraps `hook_commands`, sources `init_script` once

ToolEntry :: struct {
	name:          string, // recipe label; for evalcache also the binary to invoke
	kind:          string, // "evalcache" | "nvm" | "conda" | "lazy"
	args:          string, // evalcache: extra args (e.g. "init zsh")
	eager:         bool, // evalcache: load in core instead of lazy
	login_only:    bool, // only load in login shells (login.zsh)
	init_script:   string, // lazy: path sourced on first hook invocation
	hook_commands: []string, // lazy: commands wrapped to trigger load
}

destroy_tool_entry :: proc(t: ^ToolEntry) {
	if len(t.name) > 0 {
		delete(t.name)
	}
	if len(t.kind) > 0 {
		delete(t.kind)
	}
	if len(t.args) > 0 {
		delete(t.args)
	}
	if len(t.init_script) > 0 {
		delete(t.init_script)
	}
	for s in t.hook_commands {delete(s)}
	if len(t.hook_commands) > 0 {
		delete(t.hook_commands)
	}
}

// Caller must destroy_tool_entry each element + `delete` the dynamic array.
read_wayu_toml_tools :: proc() -> [dynamic]ToolEntry {
	content_str, ok := get_cached_toml_content()
	if !ok {
		return make([dynamic]ToolEntry)
	}

	// Growing virtual arena: the old fixed arena (capped at 512KB) ran out on
	// large configs (thousands of aliases) and segfaulted every regenerate.
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		return make([dynamic]ToolEntry)
	}
	defer virtual.arena_destroy(&arena)

	doc, _ := toml_doc_parse_alloc(content_str, virtual.arena_allocator(&arena))
	tools_val, has := doc.values["tools"]
	if !has || tools_val == nil || tools_val.type != .TABLE {
		return make([dynamic]ToolEntry)
	}

	// wayu.toml file order (OKAMI-365): a tool's init may depend on an
	// earlier one (they were sorted by name).
	names := toml_tools_file_order(&doc)
	defer delete(names)

	entries := make([dynamic]ToolEntry)
	for name in names {
		val := tools_val.table_val[name]
		if val == nil || val.type != .TABLE {
			continue
		}
		append(&entries, tool_entry_from_inline_table(name, val))
	}
	return entries
}

// [tools] entry names in the order they first appear in wayu.toml: an
// entry under [tools], a [tools.<name>] header, or a dotted
// `tools.<name>...` key. The names slice the doc (caller deletes the array).
@(private = "file")
toml_tools_file_order :: proc(doc: ^TomlDoc) -> [dynamic]string {
	Seen :: struct {
		line: int,
		name: string,
	}
	found := make([dynamic]Seen, context.temp_allocator)
	for h in doc.headers {
		if !h.array && len(h.path) >= 2 && h.path[0] == "tools" {
			append(&found, Seen{h.line, h.path[1]})
		}
	}
	for e in doc.entries {
		full := e.key
		if e.header >= 0 {
			hp := doc.headers[e.header].path
			if doc.headers[e.header].array {
				continue
			}
			full = slice.concatenate([][]string{hp, e.key}, context.temp_allocator)
		}
		if len(full) >= 2 && full[0] == "tools" {
			append(&found, Seen{e.first, full[1]})
		}
	}
	slice.stable_sort_by(found[:], proc(a, b: Seen) -> bool {return a.line < b.line})
	names := make([dynamic]string)
	for f in found {
		if !slice.contains(names[:], f.name) {
			append(&names, f.name)
		}
	}
	return names
}

// `kind` defaults to "evalcache" so terse entries like `zoxide = { args = "init zsh" }` work.
tool_entry_from_inline_table :: proc(name: string, table: ^TomlValue) -> ToolEntry {
	entry: ToolEntry
	entry.name = strings.clone(name)
	entry.kind = strings.clone("evalcache")

	if v, ok := table.table_val["kind"]; ok && v != nil && v.type == .STRING {
		delete(entry.kind)
		entry.kind = strings.clone(v.str_val)
	}
	if v, ok := table.table_val["args"]; ok && v != nil && v.type == .STRING {
		entry.args = strings.clone(v.str_val)
	}
	if v, ok := table.table_val["eager"]; ok && v != nil && v.type == .BOOLEAN {
		entry.eager = v.bool_val
	}
	if v, ok := table.table_val["login_only"]; ok && v != nil && v.type == .BOOLEAN {
		entry.login_only = v.bool_val
	}
	if v, ok := table.table_val["init_script"]; ok && v != nil && v.type == .STRING {
		entry.init_script = strings.clone(v.str_val)
	}
	if v, ok := table.table_val["hook_commands"]; ok && v != nil && v.type == .ARRAY {
		n := 0
		for elem in v.arr_val {
			if elem.type == .STRING {
				n += 1
			}
		}
		cmds := make([]string, n)
		i := 0
		for elem in v.arr_val {
			if elem.type == .STRING {
				cmds[i] = strings.clone(elem.str_val)
				i += 1
			}
		}
		entry.hook_commands = cmds
	}
	return entry
}

// ============================================================================
// Tool recipe dispatch + lazy-loader code generation
// ============================================================================

// `kind` falls back to evalcache when blank - simplifies the terse form
// `zoxide = { args = "init zsh" }`.
tool_kind_is_evalcache :: proc(kind: string) -> bool {
	return len(kind) == 0 || kind == "evalcache"
}

// `_wayu_evalcache <name> <args>`. `args` is the tool's argv ("init zsh
// --disable-up-arrow"): split into words by tool_args_to_shell and each word
// re-quoted, so the value can never run code at startup. Unusable args skip
// the tool (comment in the file, warning on stderr — stdout of `wayu build
// eval` is eval'd); `wayu build` refuses them up front (validate_tools_args).
emit_evalcache_call :: proc(b: ^strings.Builder, t: ToolEntry) {
	if !tool_name_ok(b, t.name) {
		return
	}
	if len(t.args) == 0 {
		fmt.sbprintfln(b, "_wayu_evalcache %s", t.name)
		return
	}
	// `args = "init zsh"` also serves core.bash (OKAMI-313): retargeted to
	// the shell this core is for, like fish.
	words, reason, ok := tool_args_to_shell(
		t.args,
		retarget = "bash" if wayu.shell == .BASH else "zsh",
	)
	defer if ok {
		delete(words)
	}
	if !ok {
		fmt.sbprintfln(b, "# wayu: [tools] %s: args %s - skipping", t.name, reason)
		fmt.eprintfln("[wayu] [tools] %s: args %s - skipping", t.name, reason)
		return
	}
	fmt.sbprintfln(b, "_wayu_evalcache %s %s", t.name, words)
}

// Split a [tools] `args` value into words the way the shell would (quotes
// and backslashes honoured) and re-emit each word quoted. Kept expandable:
// `$NAME` / `${NAME...}` variables (as in [env] values) and a leading `~/`.
// Refused, with a reason: newline, operators (; & | < > ( )), command
// substitution ($(...), backticks), glob characters (* ? [) and a word
// mixing quoted and unquoted `$`. Brace expansion is not performed: `{a,b}`
// stays literal. `retarget` (a shell name): the words `zsh` / `bash`
// become it and `--zsh` / `--bash` become `--<retarget>`, so one [tools]
// entry (`args = "init zsh"`) serves every shell's core. `out` is allocated
// with `allocator` (owned by the caller when ok); `reason` is static or
// temp-allocated.
tool_args_to_shell :: proc(
	args: string,
	allocator := context.allocator,
	retarget := "",
) -> (
	out: string,
	reason: string,
	ok: bool,
) {
	if strings.contains_any(args, "\n\r") {
		return "", "contains a newline", false
	}
	stmts := shell_parse_statements(args, .POSIX)
	defer shell_statements_destroy(&stmts)
	if len(stmts) == 0 {
		return strings.clone("", allocator), "", true
	}
	st := stmts[0]
	if len(st.error) > 0 {
		return "", fmt.tprintf("cannot be parsed (%s)", st.error), false
	}

	sb := strings.builder_make(allocator)
	defer if !ok {
		strings.builder_destroy(&sb)
	}
	for tok, ti in st.tokens {
		if tok.kind == .Op {
			return "", fmt.tprintf("contains the shell operator %q", tok.op), false
		}
		text, active := tok.word.text, tok.word.active
		dollar_active, dollar_quoted := false, false
		for i in 0 ..< len(text) {
			c := text[i]
			if !active[i] {
				if c == '$' {
					dollar_quoted = true
				}
				continue
			}
			switch c {
			case '`':
				return "", "contains command substitution (`...`)", false
			case '$':
				if i + 1 < len(text) && text[i + 1] == '(' {
					return "", "contains command substitution ($(...))", false
				}
				dollar_active = true
			case '*', '?', '[':
				return "", fmt.tprintf("contains the glob character %q", c), false
			}
		}
		if dollar_active && dollar_quoted {
			return "", fmt.tprintf("word %q mixes quoted and unquoted $", text), false
		}
		tilde := len(active) > 0 && active[0] && (text == "~" || strings.has_prefix(text, "~/"))
		// After the per-byte checks (`active` is indexed by `text`).
		if len(retarget) > 0 {
			switch text {
			case "zsh", "bash":
				text = retarget
			case "--zsh", "--bash":
				text = fmt.tprintf("--%s", retarget)
			}
		}

		if ti > 0 {
			strings.write_byte(&sb, ' ')
		}
		// Heap, not the temp arena: a huge config (thousands of aliases)
		// can exhaust the arena, and a failed temp allocation would
		// silently drop the args.
		quoted := ""
		switch {
		case dollar_active || (tilde && !dollar_quoted):
			v := expand_leading_tilde_to_home_var(text) if tilde else strings.clone(text)
			quoted = shell_double_quote_env(v)
			delete(v)
		case tilde:
			strings.write_string(&sb, "~/" if len(text) > 1 else "~")
			if len(text) > 2 {
				quoted = shell_single_quote(text[2:])
			}
		case len(text) > 0 && is_bare_shell_word(text):
			strings.write_string(&sb, text)
		case:
			quoted = shell_single_quote(text)
		}
		strings.write_string(&sb, quoted)
		delete(quoted)
	}
	return strings.to_string(sb), "", true
}

// Only characters no shell (zsh/bash, any options) treats specially.
@(private = "file")
is_bare_shell_word :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		case c == '-' ||
		     c == '_' ||
		     c == '.' ||
		     c == '/' ||
		     c == ',' ||
		     c == ':' ||
		     c == '+' ||
		     c == '@' ||
		     c == '%':
		case c == '=' && i > 0:
		case:
			return false
		}
	}
	return true
}

// `wayu build`: refuse [tools] entries whose args the generator would skip,
// naming the tool, before anything is written. Returns false after printing.
validate_tools_args :: proc() -> bool {
	tools := read_wayu_toml_tools()
	defer {
		for &t in tools {destroy_tool_entry(&t)}
		delete(tools)
	}
	ok := true
	for t in tools {
		if !tool_kind_is_evalcache(t.kind) || len(t.args) == 0 {
			continue
		}
		words, reason, valid := tool_args_to_shell(t.args)
		if valid {
			delete(words)
		} else {
			print_error("wayu.toml [tools] %s: args %s", t.name, reason)
			ok = false
		}
	}
	if !ok {
		fmt.println(
			"  Write args as plain words, quoting with '...' where needed (no ; | & < > newlines, $(...), backticks or globs).",
		)
	}
	return ok
}

// Emit the deferred init code for a single tool entry.
// Eager evalcache tools are handled in core; this dispatcher runs from
// lazy/login and covers everything else (deferred evalcache + heavy recipes).
emit_tool_recipe :: proc(b: ^strings.Builder, t: ToolEntry) {
	if !tool_name_ok(b, t.name) {
		return
	}
	is_zsh := wayu.shell == .ZSH
	switch {
	case tool_kind_is_evalcache(t.kind):
		emit_evalcache_call(b, t)
	case t.kind == "nvm":
		fmt.sbprintln(b, "# --- recipe: nvm (lazy) ---")
		fmt.sbprintln(b, RECIPE_NVM_ZSH if is_zsh else RECIPE_NVM_BASH)
	case t.kind == "conda":
		fmt.sbprintln(b, "# --- recipe: conda (lazy) ---")
		fmt.sbprintln(b, RECIPE_CONDA_ZSH if is_zsh else RECIPE_CONDA_BASH)
	case t.kind == "lazy":
		emit_lazy_recipe(b, t)
	case:
		fmt.sbprintfln(b, "# wayu: unknown kind %q for tool %q - skipping", t.kind, t.name)
	}
}

// A [tools] key must be a valid alias name for every kind: it is printed in
// generated comments and code, and a TOML quoted key can hold a newline that
// would end a `# ...` comment and start a command. Otherwise the entry is
// skipped with a comment (%q-escaped) and a warning on stderr.
tool_name_ok :: proc(b: ^strings.Builder, name: string) -> bool {
	if is_safe_alias_name(name) {
		return true
	}
	fmt.sbprintfln(b, "# wayu: invalid tool name %q - skipping", name)
	fmt.eprintfln("[wayu] [tools] invalid tool name %q - skipping", name)
	return false
}

// Generic lazy recipe: wrap each `hook_commands` entry so the first call
// sources `init_script` once and re-invokes the original command.
// The emitted code is valid in both zsh and bash (`; }` terminators,
// `[ -n ]` guard instead of zsh-only arithmetic on an unset var).
//
// Note: Odin's fmt package treats `{` as the start of an indexed verb, so
// shell brace characters are appended via plain `sbprint` to keep the
// generated script readable and verb-error-free.
emit_lazy_recipe :: proc(b: ^strings.Builder, t: ToolEntry) {
	if len(t.init_script) == 0 || len(t.hook_commands) == 0 {
		fmt.sbprintfln(
			b,
			"# wayu: 'lazy' kind for %q needs init_script + hook_commands - skipping",
			t.name,
		)
		return
	}

	ident := sanitize_ident(t.name)
	loader := fmt.tprintf("_wayu_lazy_%s_load", ident)
	flag := fmt.tprintf("_WAYU_LAZY_%s_LOADED", strings.to_upper(ident, context.temp_allocator))

	cmds := make([dynamic]string, 0, len(t.hook_commands), context.temp_allocator)
	for cmd in t.hook_commands {
		if is_safe_alias_name(cmd) {
			append(&cmds, cmd)
		} else {
			fmt.sbprintfln(b, "# wayu: invalid hook command %q for %q - skipping", cmd, t.name)
		}
	}
	if len(cmds) == 0 {
		return
	}

	script := shell_double_quote_env(
		expand_leading_tilde_to_home_var(t.init_script, context.temp_allocator),
		context.temp_allocator,
	)

	fmt.sbprintfln(b, "# --- recipe: lazy (%s) ---", t.name)
	fmt.sbprint(b, loader)
	fmt.sbprintln(b, "() {")
	// `${FLAG-}`: stays valid under `set -u` (OKAMI-210).
	fmt.sbprint(b, "  [ -n \"${")
	fmt.sbprint(b, flag)
	fmt.sbprintln(b, "-}\" ] && return 0")
	fmt.sbprintfln(b, "  %s=1", flag)
	fmt.sbprint(b, "  unset -f")
	for cmd in cmds {fmt.sbprintf(b, " %s", cmd)}
	fmt.sbprintln(b, " 2>/dev/null")
	fmt.sbprintfln(b, "  [ -s %s ] && \\. %s", script, script)
	fmt.sbprintln(b, "}")
	// `function name {` and `\name`: an alias named like the hook command
	// (defined before wayu is sourced) must not hijack the definition or the
	// re-invocation — `name() {` is alias-expanded while parsing.
	for cmd in cmds {
		fmt.sbprint(b, "function ")
		fmt.sbprint(b, cmd)
		fmt.sbprint(b, " { ")
		fmt.sbprint(b, loader)
		fmt.sbprint(b, "; \\")
		fmt.sbprint(b, cmd)
		fmt.sbprintln(b, " \"$@\"; }")
	}
}

// Replace anything that isn't a portable shell-identifier char with `_`.
// Tool names come from TOML keys so they're usually fine, but lazy recipes
// inject them into function names - stay defensive.
sanitize_ident :: proc(s: string) -> string {
	buf := make([]byte, len(s), context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', c == '_':
			buf[i] = c
		case:
			buf[i] = '_'
		}
	}
	return string(buf)
}

// Lazy NVM recipe (zsh). Prepend the default node version to PATH instantly,
// wrap nvm/node/npm/npx/corepack so the real nvm.sh (~5000 lines) is only
// sourced on first nvm call, and switch versions on `cd` into a directory
// with a .nvmrc / .node-version file via a pure-zsh PATH swap. The chpwd
// hook stays _wayu_chpwd_nvmrc after nvm loads (it used to be swapped to an
// undefined `load-nvmrc`).
//
// _wayu_nvm_resolve <spec> sets REPLY to the bin dir nvm itself would pick
// (OKAMI-222): alias files are followed (default -> lts/iron -> v20.18.0,
// lts/* included), a leading `v` is optional, `node`/`stable` mean the newest
// install, and a partial version matches whole components only (`20.1` is
// 20.1.x, never 20.18.0) with the highest match winning — candidates are
// sorted numerically (`nOn`), not lexicographically.
//
// Option/alias hardening (OKAMI-224): option-sensitive code runs under
// `emulate -L zsh`; wrappers are declared `function name {` and re-invoke
// `\name`, so an alias named node/npm/nvm defined before wayu can't hijack
// them; no external commands (ls/sort/tail) are used.
RECIPE_NVM_ZSH :: `_wayu_nvm_resolve() {
  emulate -L zsh -o extended_glob
  REPLY=""
  local spec="${1//[[:space:]]/}" d v
  integer hops=0 any=0
  while [[ -n $spec && -f "$NVM_DIR/alias/$spec" ]] && (( hops++ < 10 )); do
    spec="$(<"$NVM_DIR/alias/$spec")"
    spec="${spec//[[:space:]]/}"
  done
  [[ $spec == (node|stable) ]] && any=1
  spec="${spec#v}"
  (( any )) || [[ $spec == <->(.<->)# ]] || return 1
  for d in "$NVM_DIR"/versions/node/v*(N/nOn); do
    v="${d:t}"
    v="${v#v}"
    (( any )) || [[ $v == $spec || $v == $spec.* ]] || continue
    [[ -d $d/bin ]] && { REPLY="$d/bin"; return 0 }
  done
  return 1
}

_wayu_setup_nvm_lazy() {
  # Point PATH to NVM's default node (instant, no subprocess).
  local REPLY
  _wayu_nvm_resolve default && export PATH="$REPLY:$PATH"

  function _wayu_load_nvm {
    if (( ${_WAYU_NVM_LOADED:-0} )); then return; fi
    _WAYU_NVM_LOADED=1
    unset -f nvm node npm npx corepack 2>/dev/null
    local nvm_sh=""
    [ -s "$NVM_DIR/nvm.sh" ] && nvm_sh="$NVM_DIR/nvm.sh"
    [ -z "$nvm_sh" ] && [ -s "/opt/homebrew/opt/nvm/nvm.sh" ] && nvm_sh="/opt/homebrew/opt/nvm/nvm.sh"
    [ -z "$nvm_sh" ] && [ -s "/usr/local/opt/nvm/nvm.sh" ] && nvm_sh="/usr/local/opt/nvm/nvm.sh"
    [ -n "$nvm_sh" ] && \. "$nvm_sh"
    local nvm_completion=""
    [ -s "$NVM_DIR/bash_completion" ] && nvm_completion="$NVM_DIR/bash_completion"
    [ -z "$nvm_completion" ] && [ -s "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm" ] && nvm_completion="/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm"
    [ -n "$nvm_completion" ] && \. "$nvm_completion"
  }

  function _wayu_run_node_bin {
    local cmd="$1"; shift
    unset -f "$cmd" 2>/dev/null
    local bin_path="$(command -v "$cmd" 2>/dev/null)"
    local _exit_code
    if [[ -n "$bin_path" ]]; then
      "$bin_path" "$@"
      _exit_code=$?
    else
      _wayu_load_nvm
      "$cmd" "$@"
      _exit_code=$?
    fi
    eval "function $cmd { _wayu_run_node_bin $cmd \"\$@\" }"
    return $_exit_code
  }

  function nvm      { _wayu_load_nvm; \nvm "$@" }
  function node     { _wayu_run_node_bin node "$@" }
  function npm      { _wayu_run_node_bin npm "$@" }
  function npx      { _wayu_run_node_bin npx "$@" }
  function corepack { _wayu_run_node_bin corepack "$@" }

  function _wayu_fast_nvmrc {
    emulate -L zsh
    local nvmrc_file=""
    [[ -f ".nvmrc" ]]        && nvmrc_file=".nvmrc"
    [[ -f ".node-version" ]] && nvmrc_file=".node-version"
    [[ -z "$nvmrc_file" ]] && return 1
    local REPLY p nvm_prefix="$NVM_DIR/versions/node/"
    _wayu_nvm_resolve "$(<"$nvmrc_file")" || return 1
    local -a new_parts
    for p in "${(@s/:/)PATH}"; do
      [[ "$p" == ${nvm_prefix}* ]] && continue
      new_parts+=("$p")
    done
    export PATH="$REPLY:${(j/:/)new_parts}"
    return 0
  }

  function _wayu_chpwd_nvmrc {
    if [[ -f ".nvmrc" ]] || [[ -f ".node-version" ]]; then
      _wayu_fast_nvmrc || { _wayu_load_nvm; \nvm use --silent >/dev/null 2>&1 }
    fi
  }
  autoload -Uz add-zsh-hook 2>/dev/null
  add-zsh-hook chpwd _wayu_chpwd_nvmrc 2>/dev/null
  _wayu_fast_nvmrc
}
if [ -d "${NVM_DIR:=$HOME/.nvm}" ]; then export NVM_DIR; _wayu_setup_nvm_lazy; fi`

// Lazy NVM recipe (bash). Same idea, bash syntax: default node goes on PATH
// immediately; only `nvm` itself is wrapped (node/npm resolve via PATH).
// _wayu_nvm_resolve mirrors the zsh one (see RECIPE_NVM_ZSH) in bash 3.2:
// no numeric glob sort, so versions are compared component-wise.
RECIPE_NVM_BASH :: `_wayu_nvm_ver_gt() {
  local IFS=. i
  local -a x y
  read -r -a x <<< "$1"
  read -r -a y <<< "$2"
  for i in 0 1 2; do
    [ "$((10#${x[i]:-0}))" -gt "$((10#${y[i]:-0}))" ] && return 0
    [ "$((10#${x[i]:-0}))" -lt "$((10#${y[i]:-0}))" ] && return 1
  done
  return 1
}
_wayu_nvm_resolve() {
  local spec="${1//[[:space:]]/}" hops=0 any=0 d v best="" best_v=""
  REPLY=""
  while [ -n "$spec" ] && [ -f "$NVM_DIR/alias/$spec" ] && [ "$hops" -lt 10 ]; do
    spec="$(<"$NVM_DIR/alias/$spec")"
    spec="${spec//[[:space:]]/}"
    hops=$((hops + 1))
  done
  case "$spec" in node|stable) any=1 ;; esac
  spec="${spec#v}"
  if [ "$any" = 0 ]; then
    case "$spec" in ""|.*|*.|*..*|*[!0-9.]*) return 1 ;; esac
  fi
  for d in "$NVM_DIR"/versions/node/v*; do
    [ -d "$d/bin" ] || continue
    v="${d##*/}"
    v="${v#v}"
    case "$v" in ""|*[!0-9.]*) continue ;; esac
    if [ "$any" = 0 ] && [ "$v" != "$spec" ]; then
      case "$v" in "$spec".*) ;; *) continue ;; esac
    fi
    if [ -z "$best_v" ] || _wayu_nvm_ver_gt "$v" "$best_v"; then
      best_v="$v"
      best="$d/bin"
    fi
  done
  [ -n "$best" ] || return 1
  REPLY="$best"
}
_wayu_setup_nvm_lazy() {
  local REPLY
  _wayu_nvm_resolve default && export PATH="$REPLY:$PATH"
  return 0
}
_wayu_load_nvm() {
  [ -n "${_WAYU_NVM_LOADED-}" ] && return 0
  _WAYU_NVM_LOADED=1
  unset -f nvm 2>/dev/null
  local nvm_sh=""
  [ -s "$NVM_DIR/nvm.sh" ] && nvm_sh="$NVM_DIR/nvm.sh"
  [ -z "$nvm_sh" ] && [ -s "/opt/homebrew/opt/nvm/nvm.sh" ] && nvm_sh="/opt/homebrew/opt/nvm/nvm.sh"
  [ -z "$nvm_sh" ] && [ -s "/usr/local/opt/nvm/nvm.sh" ] && nvm_sh="/usr/local/opt/nvm/nvm.sh"
  [ -n "$nvm_sh" ] && \. "$nvm_sh"
  [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
  return 0
}
function nvm { _wayu_load_nvm; \nvm "$@"; }
if [ -d "${NVM_DIR:=$HOME/.nvm}" ]; then export NVM_DIR; _wayu_setup_nvm_lazy; fi`

// Lazy Conda recipe (zsh). Conda's own `conda init` block spawns Python at every
// shell start (~500ms); this version defers that work until the first call
// to conda/mamba.
//
// Only `conda`/`mamba` trigger the load — deliberately not python/pip. Conda
// puts a full toolchain on PATH (its own python, pip, and an ancient ld), so
// loading it from a bare `python` call silently shadows system tools for the
// rest of the session. Nothing from conda enters PATH until the user asks for
// it by name.
RECIPE_CONDA_ZSH :: `_wayu_setup_conda_lazy() {
  local conda_root=""
  [ -d "$HOME/anaconda3" ]               && conda_root="$HOME/anaconda3"
  [ -z "$conda_root" ] && [ -d "$HOME/miniconda3" ]    && conda_root="$HOME/miniconda3"
  [ -z "$conda_root" ] && [ -d "$HOME/miniforge3" ]    && conda_root="$HOME/miniforge3"
  [ -z "$conda_root" ] && [ -d "/opt/homebrew/anaconda3" ] && conda_root="/opt/homebrew/anaconda3"
  [ -z "$conda_root" ] && [ -d "/opt/anaconda3" ]      && conda_root="/opt/anaconda3"
  [ -z "$conda_root" ] && return

  # Global, not local: _wayu_load_conda runs long after this function has
  # returned, so a local would be empty at call time and the hook would
  # silently never load.
  typeset -g _WAYU_CONDA_ROOT="$conda_root"

  _wayu_load_conda() {
    if (( ${_WAYU_CONDA_LOADED:-0} )); then return; fi
    _WAYU_CONDA_LOADED=1
    unset -f conda mamba 2>/dev/null
    local hook_out
    hook_out="$("$_WAYU_CONDA_ROOT/bin/conda" shell.zsh hook 2>/dev/null)"
    if [[ -n "$hook_out" ]]; then
      eval "$hook_out"
    elif [ -f "$_WAYU_CONDA_ROOT/etc/profile.d/conda.sh" ]; then
      \. "$_WAYU_CONDA_ROOT/etc/profile.d/conda.sh"
    fi
    # Last resort: if neither path produced a usable conda, put its bin on
    # PATH. Only reachable after an explicit conda/mamba call, never at startup.
    if ! (( $+functions[conda] )) && ! command -v conda >/dev/null 2>&1; then
      export PATH="$_WAYU_CONDA_ROOT/bin:$PATH"
    fi
  }

  function conda { _wayu_load_conda; \conda "$@" }
  function mamba { _wayu_load_conda; \mamba "$@" }
}
_wayu_setup_conda_lazy`

// Lazy Conda recipe (bash).
RECIPE_CONDA_BASH :: `_wayu_setup_conda_lazy() {
  local conda_root=""
  [ -d "$HOME/anaconda3" ]               && conda_root="$HOME/anaconda3"
  [ -z "$conda_root" ] && [ -d "$HOME/miniconda3" ]    && conda_root="$HOME/miniconda3"
  [ -z "$conda_root" ] && [ -d "$HOME/miniforge3" ]    && conda_root="$HOME/miniforge3"
  [ -z "$conda_root" ] && [ -d "/opt/homebrew/anaconda3" ] && conda_root="/opt/homebrew/anaconda3"
  [ -z "$conda_root" ] && [ -d "/opt/anaconda3" ]      && conda_root="/opt/anaconda3"
  [ -z "$conda_root" ] && return 0
  _WAYU_CONDA_ROOT="$conda_root"

  _wayu_load_conda() {
    [ -n "${_WAYU_CONDA_LOADED-}" ] && return 0
    _WAYU_CONDA_LOADED=1
    unset -f conda mamba 2>/dev/null
    local hook_out
    hook_out="$("$_WAYU_CONDA_ROOT/bin/conda" shell.bash hook 2>/dev/null)"
    if [ -n "$hook_out" ]; then
      eval "$hook_out"
    elif [ -f "$_WAYU_CONDA_ROOT/etc/profile.d/conda.sh" ]; then
      \. "$_WAYU_CONDA_ROOT/etc/profile.d/conda.sh"
    fi
    if ! declare -F conda >/dev/null && ! command -v conda >/dev/null 2>&1; then
      export PATH="$_WAYU_CONDA_ROOT/bin:$PATH"
    fi
    return 0
  }

  function conda { _wayu_load_conda; \conda "$@"; }
  function mamba { _wayu_load_conda; \mamba "$@"; }
}
_wayu_setup_conda_lazy`

// ============================================================================
// Env / alias entries from the entry store (entries.odin)
// ============================================================================

EnvEntry :: struct {
	name:  string,
	value: string,
}

// The store's constants in ORDER so later values can reference earlier ones
// (GOBIN = "$GOPATH/bin" after GOPATH). Empty "" values are kept. Secret
// constants (stored encrypted, no value in entries.json) are not part of
// the generated files.
read_env_values :: proc() -> [dynamic]EnvEntry {
	store := entries_load()
	defer entries_store_destroy(&store)
	entries := make([dynamic]EnvEntry, 0, len(store.env))
	for e in store.env {
		if e.secret {
			continue
		}
		append(&entries, EnvEntry{name = strings.clone(e.name), value = strings.clone(e.value)})
	}
	return entries
}

// The store's aliases, sorted by name for deterministic output. AliasEntry
// is defined in colors.odin.
read_alias_values :: proc() -> [dynamic]AliasEntry {
	store := entries_load()
	defer entries_store_destroy(&store)
	entries := make([dynamic]AliasEntry, 0, len(store.aliases))
	for a in store.aliases {
		append(
			&entries,
			AliasEntry{name = strings.clone(a.name), command = strings.clone(a.value)},
		)
	}
	slice.sort_by(entries[:], proc(a, b: AliasEntry) -> bool {return a.name < b.name})
	return entries
}

// ============================================================================
// Fish core generator
// ============================================================================
//
// Fish syntax is incompatible with bash/zsh, so we emit a dedicated
// core.fish rather than sharing build_core_content. Same sections in the
// same order as core.zsh/core.bash (OKAMI-268): env, PATH (+ live sync via
// path_sync.fish), completions, functions, config.fish, evalcache helper,
// eager tools, plugins, deferred tools, login-only tools, aliases. There is
// no zsh-defer in fish: "deferred" tools just run after the plugins.
// init.fish sources tools.fish then extra.fish after core.fish.
// An existing turbo.fish is rewritten too (`wayu export --turbo`).
generate_core_init_fish :: proc() {
	path := fmt.aprintf("%s/core.fish", wayu.data)
	defer delete(path)
	sync_file := write_path_sync_file()
	defer delete(sync_file)

	content := build_core_content_fish()
	defer delete(content)
	write_init_file(path, content)

	turbo := fmt.tprintf("%s/turbo.fish", wayu.data)
	if os.exists(turbo) {
		turbo_content := fish_turbo_content(content)
		defer delete(turbo_content)
		write_turbo_file(turbo, turbo_content)
	}
}

// turbo.fish: core.fish plus what init.fish sources after it (tools.fish,
// extra.fish), so sourcing turbo.fish alone equals sourcing init.fish.
// Caller owns the result.
fish_turbo_content :: proc(core: string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, core)
	fmt.sbprintln(&b)
	for name in ([]string{"tools", "extra"}) {
		q := escape_fish_string(
			fmt.tprintf("%s/%s.fish", wayu.config, name),
			context.temp_allocator,
		)
		fmt.sbprintfln(&b, "# === User %s.fish ===", name)
		fmt.sbprintfln(&b, "test -f %s; and source %s", q, q)
	}
	return strings.to_string(b)
}

// `set -gx NAME "value"` per [env] entry: double-quoted so $VAR expands,
// `~/` → $HOME/ (fish_double_quote_env). `mask` hides secret-looking values
// (dry-run previews).
emit_env_exports_fish :: proc(b: ^strings.Builder, mask := false) {
	toml_env := read_env_values()
	defer {
		for e in toml_env {delete(e.name); delete(e.value)}
		delete(toml_env)
	}
	for e in toml_env {
		if !is_shell_var_name(e.name) {
			fmt.sbprintfln(b, "# wayu: skipping invalid env name %q", e.name)
			continue
		}
		// A protected name stored by hand (doctor reports it) is not set.
		if len(protected_env_name_error(e.name)) > 0 {
			fmt.sbprintfln(b, "# wayu: skipping protected env name %s", e.name)
			continue
		}
		v := expand_leading_tilde_to_home_var(e.value, context.temp_allocator)
		if mask {
			v = mask_secret_value(e.name, e.value)
		}
		fmt.sbprintfln(
			b,
			`set -gx %s %s`,
			e.name,
			fish_double_quote_env(v, context.temp_allocator),
		)
	}
}

// One function per [aliases] entry, what fish's `alias` defines, except that
// the body is never spliced into code: `alias` sources
// "function NAME; BODY $argv; end", so a body holding `end; ...` ran at
// startup. Here the body is one escaped word, run by `eval` at call time with
// the arguments escaped (taken literally, as zsh/bash pass them after an
// alias). As in `alias`: a body starting with NAME runs it as `command` (or
// `builtin`) instead of recursing; --wraps (completions) unless the first or
// last word is NAME; the description `alias NAME BODY` keeps `alias` listing
// them.
emit_alias_definitions_fish :: proc(b: ^strings.Builder) {
	toml_aliases := read_alias_values()
	defer {
		for a in toml_aliases {delete(a.name); delete(a.command)}
		delete(toml_aliases)
	}
	for a in toml_aliases {
		if !is_safe_alias_name(a.name) {
			fmt.sbprintfln(b, "# wayu: skipping invalid alias name %q", a.name)
			continue
		}
		emit_alias_function_fish(b, a.name, a.command)
	}
}

emit_alias_function_fish :: proc(b: ^strings.Builder, name, body: string) {
	// fish's `alias` splits the body on whitespace (`read --list`).
	words := strings.fields(body, context.temp_allocator)
	first := len(words) > 0 ? words[0] : ""
	last := len(words) > 0 ? words[len(words) - 1] : ""
	qbody := escape_fish_string(body, context.temp_allocator)
	fmt.sbprintf(b, "function %s", name)
	if first != name && last != name {
		fmt.sbprintf(b, " --wraps %s", qbody)
	}
	fmt.sbprintfln(
		b,
		" --description %s",
		escape_fish_string(fmt.tprintf("alias %s %s", name, body), context.temp_allocator),
	)
	if first == name {
		fmt.sbprintln(b, "    set -l p command")
		fmt.sbprintfln(b, "    contains -- %s (builtin --names); and set p builtin", name)
		fmt.sbprintfln(b, "    eval $p %s (string escape -- $argv)", qbody)
	} else {
		fmt.sbprintfln(b, "    eval %s (string escape -- $argv)", qbody)
	}
	fmt.sbprintln(b, "end")
}

// `wayu export --eval` for fish (`wayu export --eval | source`): [paths]
// dirs in front of PATH (existing dirs only, no duplicates), like core.fish
// at startup but without the live sync.
emit_path_eval_fish :: proc(b: ^strings.Builder) {
	values := read_path_values()
	script_path_prepend(&values)
	defer {
		for v in values {delete(v)}
		delete(values)
	}
	if len(values) == 0 {
		return
	}
	fmt.sbprintln(b, "set -l _wayu_w")
	for v in values {
		word, guard := path_value_fish_word(v)
		fmt.sbprintfln(b, "%sset -a _wayu_w %s", guard, word)
	}
	fmt.sbprintln(b, "set -l _wayu_np")
	fmt.sbprintln(
		b,
		`for _wayu_p in $_wayu_w; test -d "$_wayu_p"; and not contains -- $_wayu_p $_wayu_np; and set -a _wayu_np $_wayu_p; end`,
	)
	fmt.sbprintln(b, "set -q _wayu_np[1]; and set -gx PATH $_wayu_np $PATH")
	fmt.sbprintln(b, "set -e _wayu_w _wayu_np _wayu_p")
}

// core.fish content (see generate_core_init_fish). `mask` hides
// secret-looking [env] values (dry-run previews). Caller owns the result.
build_core_content_fish :: proc(mask := false) -> string {
	builder := strings.builder_make()
	b := &builder
	sync_file := fmt.tprintf("%s/path_sync.fish", wayu.data)

	fmt.sbprintln(b, "#!/usr/bin/env fish")
	fmt.sbprintln(b, "# core.fish - generated by wayu")
	fmt.sbprintln(b)
	emit_dir_overrides(b, true)

	// Env from [env] FIRST: double-quoted so $VAR expands, `~/` → $HOME/.
	// [paths] below may reference these (e.g. `$GOPATH/bin`).
	fmt.sbprintln(b, "# === Environment ===")
	emit_env_exports_fish(b, mask)
	fmt.sbprintln(b)

	// PATH: the same call path_sync.fish makes, inlined; the fish_prompt
	// hook re-sources path_sync.fish when its signature changes.
	fmt.sbprintln(b, "# === PATH ===")
	fmt.sbprint(b, WAYU_PATH_SYNC_FISH)
	fmt.sbprintfln(
		b,
		"set -g _WAYU_PATHS_FILE %s",
		escape_fish_string(sync_file, context.temp_allocator),
	)
	if self := wayu_self_path(); len(self) > 0 {
		fmt.sbprintfln(b, "set -g _WAYU_BIN %s", escape_fish_string(self, context.temp_allocator))
	}
	fmt.sbprintfln(
		b,
		"set -g _WAYU_TOML_FILE %s",
		escape_fish_string(fmt.tprintf("%s/wayu.toml", wayu.config), context.temp_allocator),
	)
	fmt.sbprintfln(
		b,
		"set -g _WAYU_ENTRIES_FILE %s",
		escape_fish_string(entries_file_path(), context.temp_allocator),
	)
	{
		values, sig := read_path_sync_values()
		defer {
			for v in values {delete(v)}
			delete(values)
		}
		emit_path_apply_call_fish(b, values[:], sig)
		fmt.sbprintln(b, "set -e _wayu_w")
	}
	fmt.sbprintln(b)
	// Secrets after the PATH apply (OKAMI-292), like core.zsh/core.bash.
	emit_secrets_loader(b, .FISH)
	emit_rc_watch(b, .FISH) // optimize.odin

	// Completions directory; `contains` keeps a re-source from adding it again.
	completions_q := escape_fish_string(
		fmt.tprintf("%s/completions", wayu.data),
		context.temp_allocator,
	)
	fmt.sbprintln(b, "# === Completions ===")
	fmt.sbprintfln(
		b,
		`contains -- %s $fish_complete_path; or set -gp fish_complete_path %s`,
		completions_q,
		completions_q,
	)
	fmt.sbprintln(b)

	// User functions (`wayu function add` writes functions/<name>.fish),
	// same as zsh/bash core. A glob with no match is not an error in `for`.
	fmt.sbprintln(b, "# === Functions ===")
	fmt.sbprintfln(
		b,
		`for _wayu_f in %s/*.fish`,
		escape_fish_string(fmt.tprintf("%s/functions", wayu.data), context.temp_allocator),
	)
	fmt.sbprintln(b, `    test -f $_wayu_f; and source $_wayu_f`)
	fmt.sbprintln(b, "end")
	fmt.sbprintln(b, "set -e _wayu_f")
	fmt.sbprintln(b)

	// User config.fish
	config_fish := fmt.aprintf("%s/config.fish", wayu.config)
	defer delete(config_fish)
	if os.exists(config_fish) {
		content, ok := safe_read_file(config_fish)
		if ok {
			defer delete(content)
			if len(content) > 0 {
				fmt.sbprintln(b, "# === User configuration (from config.fish) ===")
				fmt.sbprintln(b, string(content))
			}
		}
	}

	tools := read_wayu_toml_tools()
	defer {
		for &t in tools {destroy_tool_entry(&t)}
		delete(tools)
	}
	if len(tools) > 0 || fish_has_generators() {
		fmt.sbprintln(b, "# === Helpers (evalcache) ===")
		fmt.sbprint(b, HELPER_EVALCACHE_FISH)
		fmt.sbprintln(b)
	}
	eager_count := 0
	for t in tools {
		if t.eager && !t.login_only && tool_kind_is_evalcache(t.kind) {
			eager_count += 1
		}
	}
	if eager_count > 0 {
		fmt.sbprintln(b, "# === Tools (eager - keybindings, immediate) ===")
		for t in tools {
			if !t.eager || t.login_only || !tool_kind_is_evalcache(t.kind) {
				continue
			}
			emit_tool_recipe_fish(b, t)
		}
		fmt.sbprintln(b)
	}

	// Native prompt (opt-in, `[prompt] enabled = true`), interactive shells
	// only, before the plugins like core.zsh (prompt.odin, OKAMI-368).
	if toml_data, toml_ok := get_cached_toml_content(); toml_ok && prompt_is_enabled(toml_data) {
		fmt.sbprintln(b, "# === Prompt (wayu native, interactive shells) ===")
		prompt_cfg := parse_full_prompt_config(toml_data)
		defer destroy_full_prompt_config(&prompt_cfg)
		interactive_cfg := parse_interactive_config(toml_data)
		interactive_cfg.contexts = &prompt_cfg
		code := generate_fish_prompt(prompt_cfg, interactive_cfg)
		defer delete(code)
		fmt.sbprintln(b, "if status is-interactive")
		fmt.sbprint(b, code)
		fmt.sbprintln(b, "end")
		fmt.sbprintln(b)
	}

	// Plugin runtime (generated separately by generate_plugins_file)
	plugins_q := escape_fish_string(
		fmt.tprintf("%s/plugins.fish", wayu.data),
		context.temp_allocator,
	)
	fmt.sbprintln(b, "# === Plugins ===")
	fmt.sbprintfln(b, `if test -f %s`, plugins_q)
	fmt.sbprintfln(b, `    source %s`, plugins_q)
	fmt.sbprintln(b, "end")
	fmt.sbprintln(b)

	if len(tools) - eager_count > 0 {
		deferred := 0
		for t in tools {
			if t.login_only || (t.eager && tool_kind_is_evalcache(t.kind)) {
				continue
			}
			if deferred == 0 {
				fmt.sbprintln(b, "# === Tools (deferred) ===")
			}
			deferred += 1
			emit_tool_recipe_fish(b, t)
		}
		if deferred > 0 {
			fmt.sbprintln(b)
		}
		login := 0
		for t in tools {
			if !t.login_only {
				continue
			}
			if login == 0 {
				fmt.sbprintln(b, "# === Login shell only ===")
				fmt.sbprintln(b, "if status is-login")
			}
			login += 1
			emit_tool_recipe_fish(b, t)
		}
		if login > 0 {
			fmt.sbprintln(b, "end")
			fmt.sbprintln(b)
		}
	}

	emit_generators(b, .FISH) // optimize.odin

	// Aliases from [aliases] last (as in core.zsh/bash): fully literal
	// single-quoted body, and a plugin can't redefine one.
	fmt.sbprintln(b, "# === Aliases ===")
	emit_alias_definitions_fish(b)
	return strings.to_string(builder)
}

// fish [tools] entry. evalcache: `_wayu_evalcache <name> <args>` with the
// args re-quoted for fish and retargeted (a word `zsh` / `bash` becomes
// `fish`, `--zsh` / `--bash` becomes `--fish`), so `args = "init zsh"`
// yields `<tool> init fish | source`. Generic `lazy` needs a fish
// init_script (`*.fish`); the nvm / conda recipes are POSIX-only and are
// skipped with a comment (use nvm.fish / `conda init fish`).
emit_tool_recipe_fish :: proc(b: ^strings.Builder, t: ToolEntry) {
	if !tool_name_ok(b, t.name) {
		return
	}
	switch {
	case tool_kind_is_evalcache(t.kind):
		words, reason, ok := tool_args_to_fish(t.args)
		if !ok {
			fmt.sbprintfln(b, "# wayu: [tools] %s: args %s - skipping", t.name, reason)
			fmt.eprintfln("[wayu] [tools] %s: args %s - skipping", t.name, reason)
			return
		}
		if len(words) == 0 {
			fmt.sbprintfln(b, "_wayu_evalcache %s", t.name)
		} else {
			fmt.sbprintfln(b, "_wayu_evalcache %s %s", t.name, words)
		}
	case t.kind == "lazy" && strings.has_suffix(t.init_script, ".fish"):
		ident := sanitize_ident(t.name)
		loader := fmt.tprintf("_wayu_lazy_%s_load", ident)
		flag := fmt.tprintf(
			"_WAYU_LAZY_%s_LOADED",
			strings.to_upper(ident, context.temp_allocator),
		)
		cmds := make([dynamic]string, 0, len(t.hook_commands), context.temp_allocator)
		for cmd in t.hook_commands {
			if is_safe_alias_name(cmd) {
				append(&cmds, cmd)
			} else {
				fmt.sbprintfln(b, "# wayu: invalid hook command %q for %q - skipping", cmd, t.name)
			}
		}
		if len(cmds) == 0 {
			fmt.sbprintfln(b, "# wayu: 'lazy' kind for %q needs hook_commands - skipping", t.name)
			return
		}
		script := fish_double_quote_env(
			expand_leading_tilde_to_home_var(t.init_script, context.temp_allocator),
			context.temp_allocator,
		)
		fmt.sbprintfln(b, "# --- recipe: lazy (%s) ---", t.name)
		fmt.sbprintfln(b, "function %s", loader)
		fmt.sbprintfln(b, "    set -q %s; and return 0", flag)
		fmt.sbprintfln(b, "    set -g %s 1", flag)
		fmt.sbprint(b, "    functions -e")
		for cmd in cmds {fmt.sbprintf(b, " %s", cmd)}
		fmt.sbprintln(b)
		fmt.sbprintfln(b, "    test -s %s; and source %s", script, script)
		fmt.sbprintln(b, "end")
		for cmd in cmds {
			fmt.sbprintfln(b, "function %s", cmd)
			fmt.sbprintfln(b, "    %s", loader)
			fmt.sbprintfln(b, "    %s $argv", cmd)
			fmt.sbprintln(b, "end")
		}
	case t.kind == "lazy":
		fmt.sbprintfln(
			b,
			"# wayu: 'lazy' kind for %q needs a fish init_script (*.fish) in fish - skipping",
			t.name,
		)
	case t.kind == "nvm" || t.kind == "conda":
		fmt.sbprintfln(b, "# wayu: kind %q (%s) has no fish recipe - skipping", t.kind, t.name)
	case:
		fmt.sbprintfln(b, "# wayu: unknown kind %q for tool %q - skipping", t.kind, t.name)
	}
}

// [tools] args as fish words: validated like tool_args_to_shell (same
// refusals), each word re-quoted for fish ($VAR words double-quoted, a
// leading `~/` → $HOME), shell names retargeted to fish (see
// emit_tool_recipe_fish). Result is temp-allocated.
tool_args_to_fish :: proc(args: string) -> (out: string, reason: string, ok: bool) {
	posix, why, valid := tool_args_to_shell(args, context.temp_allocator)
	if !valid {
		return "", why, false
	}
	_ = posix
	stmts := shell_parse_statements(args, .POSIX)
	defer shell_statements_destroy(&stmts)
	sb := strings.builder_make(context.temp_allocator)
	if len(stmts) == 0 {
		return "", "", true
	}
	for tok, ti in stmts[0].tokens {
		text, active := tok.word.text, tok.word.active
		dollar := false
		for i in 0 ..< len(text) {
			if active[i] && text[i] == '$' {
				dollar = true; break
			}
		}
		tilde := len(active) > 0 && active[0] && (text == "~" || strings.has_prefix(text, "~/"))
		switch text {
		case "zsh", "bash":
			text = "fish"
		case "--zsh", "--bash":
			text = "--fish"
		}
		if ti > 0 {
			strings.write_byte(&sb, ' ')
		}
		if dollar || tilde {
			v := expand_leading_tilde_to_home_var(text, context.temp_allocator) if tilde else text
			strings.write_string(&sb, fish_double_quote_env(v, context.temp_allocator))
		} else {
			strings.write_string(&sb, escape_fish_string(text, context.temp_allocator))
		}
	}
	return strings.to_string(sb), "", true
}

// `wayu build clean`: delete the evalcache dir (see HELPER_EVALCACHE_ZSH).
// Cached init code is regenerated by the next shell. Needed when a tool's
// init output depends on its config or the environment, which the binary
// signature can't see.
clear_evalcache :: proc() {
	base := os.get_env("XDG_CACHE_HOME", context.temp_allocator)
	if len(base) == 0 {
		base = fmt.tprintf("%s/.cache", wayu.home)
	}
	dir := fmt.tprintf("%s/wayu/evalcache", base)
	if !os.exists(dir) {
		print_info("No evalcache at %s", dir)
		return
	}
	if wayu.dry_run {
		fmt.printfln("[DRY RUN] Would remove %s", dir)
		return
	}
	if err := os.remove_all(dir); err != nil {
		print_error("Failed to remove %s: %v", dir, err)
		wayu_exit(EXIT_IOERR)
	}
	print_success("Cleared evalcache (%s); new shells regenerate it", dir)
}

// Print build command help
print_build_help :: proc() {
	fmt.println()
	fmt.printfln(
		"%swayu build - Compile wayu.toml + entries.json into shell init files%s",
		BOLD,
		RESET,
	)
	fmt.println()
	fmt.printfln("%sUSAGE:%s", get_primary(), RESET)
	fmt.printfln("  wayu build              Regenerate init files from wayu.toml + entries.json")
	fmt.printfln("  wayu build turbo        Write the turbo export (see wayu export help)")
	fmt.printfln("  wayu build profile      Measure shell startup time (5-iter mean)")
	fmt.printfln("  wayu build clean        Clear cached [tools] init output (evalcache)")
	fmt.printfln("  wayu build help         Show this help")
	fmt.println()
	fmt.printfln("%sDESCRIPTION:%s", get_primary(), RESET)
	fmt.println("  Regenerates core.<ext> (the one file init.<ext> sources) and the path")
	fmt.println("  sync file for every initialized shell from wayu.toml and entries.json")
	fmt.println("  (plus plugins.json for the plugin loaders). Run it after editing them")
	fmt.println("  by hand; an existing turbo file is refreshed too.")
	fmt.println()
	fmt.printfln("%sEXAMPLES:%s", get_primary(), RESET)
	fmt.println("  wayu build              # Apply hand edits of wayu.toml / entries.json")
	fmt.println("  wayu build turbo        # Write turbo.zsh / turbo.bash")
	fmt.println()
	fmt.println("  # In ~/.zshenv (or ~/.bashrc):")
	fmt.println(`  source "${WAYU_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/wayu}/init.zsh"`)
	fmt.println()
	fmt.println("  # Measure impact on startup time:")
	fmt.println("  wayu build profile       # core vs full interactive shell")
	fmt.println()
}
