// init_generator.odin - Optimized shell init file generation
package wayu
import "core:c/libc"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
// Best-effort write for generated init files. Logs a warning on failure
// instead of silently swallowing the error.
@(private = "file")
write_init_file :: proc(path, content: string) {
	if os.write_entire_file(path, transmute([]byte)content) != nil {
		print_warning("Failed to write %s", path)
	}
}

// Technique 1: built-in zsh-defer (no external plugin required)
// Technique 2: zcompile bytecode
// Technique 3: batch exports (typeset -gx)
// Technique 4: evalcache for tools
// Technique 5: optimized compinit (24h cache)
// Technique 6: split files (core/lazy/login/helpers)

// --------------------------------------------------------------------------
// Cached wayu.toml content — shared across all commands in a single
// invocation to avoid redundant reads.  Lazy-loaded on first call; cleared
// by regenerate_init_core_silently (before regen) and generate_optimized_init_all.
// --------------------------------------------------------------------------
TOML_CONTENT_CACHE: struct {
	content:     string,
	loaded:      bool,
	owned:       bool,    // true when content was heap-allocated
} = {}

get_cached_toml_content :: proc() -> (string, bool) {
	if TOML_CONTENT_CACHE.loaded {
		if len(TOML_CONTENT_CACHE.content) == 0 { return "", false }
		return TOML_CONTENT_CACHE.content, true
	}

	config_path := fmt.aprintf("%s/wayu.toml", wayu.config)
	defer delete(config_path)

	raw, ok := safe_read_file(config_path)
	TOML_CONTENT_CACHE.loaded = true
	if !ok {
		return "", false
	}

	TOML_CONTENT_CACHE.content = string(raw)
	TOML_CONTENT_CACHE.owned   = true
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

// Queue a path for zcompile (batched). The path is NOT cloned; callers
// must ensure it lives until flush_zcompile_batch is called.
zcompile_file :: proc(path: string) {
	if wayu.shell != .ZSH { return }
	append(&ZCOMPILE_BATCH, strings.clone(path))
}

// Discard all queued zcompile paths without running them.
// Used by regenerate_init_core_silently to skip the ~10ms zsh spawn
// on write operations where bytecode freshness is not critical.
@(private = "file")
discard_zcompile_batch :: proc() {
	for p in ZCOMPILE_BATCH { delete(p) }
	clear(&ZCOMPILE_BATCH)
}

// Flush all queued zcompile paths in a single zsh invocation.
//
// Paths are passed as positional arguments to `zsh -fc` (each one
// single-quoted for the outer `sh -c`), so spaces, quotes or `$` in
// $HOME / XDG paths can neither break the command nor inject code.
@(private = "file")
flush_zcompile_batch :: proc() {
	if wayu.shell != .ZSH || len(ZCOMPILE_BATCH) == 0 {
		for p in ZCOMPILE_BATCH { delete(p) }
		clear(&ZCOMPILE_BATCH)
		return
	}

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, `zsh -fc 'for f; do zcompile -- "$f"; done' zsh`)
	for p in ZCOMPILE_BATCH {
		strings.write_byte(&builder, ' ')
		strings.write_string(&builder, shell_single_quote(p, context.temp_allocator))
	}
	strings.write_string(&builder, " >/dev/null 2>&1")

	// Fire-and-forget: fork a child to run zcompile in background.
	// The parent returns immediately. Zcompile is a non-critical
	// startup optimization; if it fails, zsh just sources the .zsh text.
	run_background_shell(strings.to_string(builder))

	for p in ZCOMPILE_BATCH { delete(p) }
	clear(&ZCOMPILE_BATCH)
}

// Absolute path of a generated runtime file: <data>/<base>.<ext>.
// Allocated with the temp allocator.
@(private = "file")
runtime_file :: proc(base: string) -> string {
	return fmt.tprintf("%s/%s.%s", wayu.data, base, get_shell_extension(wayu.shell))
}

// `[ -f "<file>" ] && source "<file>"` with the path safely quoted.
@(private = "file")
emit_source_if_exists :: proc(b: ^strings.Builder, file: string) {
	q := shell_double_quote_literal(file, context.temp_allocator)
	fmt.sbprintfln(b, "[ -f %s ] && source %s", q, q)
}

// Silently regenerate every runtime file sourced by init.{ext} after any
// mutation (path/alias/constants add/remove, template apply, hot reload).
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
	// freshly written wayu.toml (callers modify the file before calling us).
	clear_toml_content_cache()

	if wayu.shell == .FISH {
		generate_core_init_fish()
		_ = generate_plugins_runtime_config(wayu.shell)
		sync_init_orchestrator()
		clear_toml_content_cache()
		// Skip zcompile on mutations — only zcompile during explicit `wayu init`.
		// The text files work fine without bytecode; zcompile is a
		// startup-time micro-optimization that isn't worth ~10ms per CLI write.
		discard_zcompile_batch()
		return
	}

	generate_core_init_v2()
	generate_lazy_init_v2()
	// core sources login.{ext} for login shells, so it must be refreshed
	// together with core or login-only tools go stale / missing.
	generate_login_init_v2()
	generate_helpers_init_v2()
	_ = generate_plugins_runtime_config(wayu.shell)
	sync_init_orchestrator()

	// Flush cached resources after all generators have run.
	clear_toml_content_cache()
	// Skip zcompile on mutations (see comment above).
	discard_zcompile_batch()
}

// Rewrite init.{ext} with the current template when it is a wayu-generated
// orchestrator that has drifted from the template. `wayu init` only creates
// init.{ext} when missing, so without this existing users never receive
// orchestrator fixes (e.g. the fast path that double-sourced extra/tools).
// Files that don't carry the wayu header (hand-written) are left alone.
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

	write_init_file(path, template)
}

// Generate all optimized init files (v2 with all optimizations)
generate_optimized_init_all :: proc() {
	ext := get_shell_extension(wayu.shell)

	if wayu.dry_run {
		fmt.println("# [DRY RUN] No files written. Would generate:")
		if wayu.shell == .FISH {
			fmt.printfln("#   %s/core.fish", wayu.data)
		} else {
			for base in ([]string{"core", "lazy", "login", "helpers"}) {
				fmt.printfln("#   %s/%s.%s", wayu.data, base, ext)
			}
		}
		return
	}

	// Fish uses a single native core.fish; zsh-defer / lazy split is
	// zsh/bash-specific and irrelevant under fish.
	if wayu.shell == .FISH {
		generate_core_init_fish()
		if !generate_plugins_runtime_config(wayu.shell) {
			print_warning("Failed to generate plugin runtime config")
		}
		sync_init_orchestrator()
		clear_toml_content_cache()
		fmt.printfln("# Init file generated: %s/core.fish", wayu.data)
		return
	}

	// 1. Core - Only what's needed for the prompt (PATH, basic prompt)
	generate_core_init_v2()

	// 2. Lazy - tools, user escape hatches
	generate_lazy_init_v2()

	// 3. Login - Login-shell-only tools (only if configured)
	generate_login_init_v2()

	// 4. Helper functions (evalcache, zsh-defer, etc.)
	generate_helpers_init_v2()

	// 5. Runtime plugin config generated from wayu.toml
	if !generate_plugins_runtime_config(wayu.shell) {
		print_warning("Failed to generate plugin runtime config")
	}

	// 6. Keep init.{ext} in sync with the current orchestrator template
	sync_init_orchestrator()

	// Flush cached resources after all generators have run.
	clear_toml_content_cache()
	flush_zcompile_batch()

	fmt.println("# Init files generated:")
	fmt.printfln("#   %s/core.%s     (< 10ms)", wayu.data, ext)
	fmt.printfln("#   %s/lazy.%s     (tools, extra config)", wayu.data, ext)
	login_path := fmt.aprintf("%s/login.%s", wayu.data, ext)
	defer delete(login_path)
	if os.exists(login_path) {
		fmt.printfln("#   %s/login.%s    (login only)", wayu.data, ext)
	}
	fmt.printfln("#   %s/helpers.%s  (evalcache%s)", wayu.data, ext, ", built-in zsh-defer" if wayu.shell == .ZSH else "")
	if wayu.shell == .ZSH {
		fmt.println("#")
		fmt.println("# To compile to bytecode (2-3x faster):")
		fmt.printfln("#   zcompile %s/core.zsh", wayu.data)
		fmt.printfln("#   zcompile %s/lazy.zsh", wayu.data)
		fmt.println("#")
		fmt.println("# NOTE: wayu includes built-in zsh-defer, no external plugin needed")
	}
}

// Emit `export NAME="value"` lines for [env]. Values keep $VAR expansion,
// a leading `~/` becomes `$HOME/`, and `"`, `\`, backtick and `$(` are
// escaped (see shell_double_quote_env). Invalid names are skipped.
emit_env_exports :: proc(b: ^strings.Builder, sep: string = "\n") {
	toml_env := read_wayu_toml_env()
	defer {
		for e in toml_env { delete(e.name); delete(e.value) }
		delete(toml_env)
	}
	for e in toml_env {
		if !is_shell_var_name(e.name) {
			fmt.sbprintf(b, "# wayu: skipping invalid env name %q%s", e.name, sep)
			continue
		}
		v := expand_leading_tilde_to_home_var(e.value, context.temp_allocator)
		fmt.sbprintf(b, "export %s=%s%s", e.name, shell_double_quote_env(v, context.temp_allocator), sep)
	}
}

// Emit `alias name='command'` lines for [aliases]. Single quotes keep the
// command verbatim so `$VAR` expands when the alias runs.
emit_alias_definitions :: proc(b: ^strings.Builder, sep: string = "\n") {
	toml_aliases := read_wayu_toml_aliases()
	defer {
		for a in toml_aliases { delete(a.name); delete(a.command) }
		delete(toml_aliases)
	}
	for a in toml_aliases {
		if !is_safe_alias_name(a.name) {
			fmt.sbprintf(b, "# wayu: skipping invalid alias name %q%s", a.name, sep)
			continue
		}
		fmt.sbprintf(b, "alias %s=%s%s", a.name, shell_single_quote(a.command, context.temp_allocator), sep)
	}
}

// Emit a single `export PATH="a:b:$PATH"` built from [paths] (file order).
// Returns false when there are no usable entries.
emit_path_export :: proc(b: ^strings.Builder, sep: string = "\n") -> bool {
	toml_paths := read_wayu_toml_paths()
	defer {
		for p in toml_paths { delete(p) }
		delete(toml_paths)
	}
	if len(toml_paths) == 0 { return false }
	joined := strings.join(toml_paths[:], ":", context.temp_allocator)
	q := shell_double_quote_literal(joined, context.temp_allocator)
	// q is `"a:b"`; splice `:$PATH` inside the closing quote.
	fmt.sbprintf(b, "export PATH=%s:$PATH\"%s", q[:len(q)-1], sep)
	return true
}

// Source every user function file (zsh null-glob vs bash nullglob-free loop).
emit_functions_loader :: proc(b: ^strings.Builder) {
	dir := shell_double_quote_literal(fmt.tprintf("%s/functions", wayu.config), context.temp_allocator)
	if wayu.shell == .ZSH {
		fmt.sbprintfln(b, `for f in %s/*(N); do [[ -f "$f" ]] && source "$f"; done`, dir)
	} else {
		fmt.sbprintfln(b, `if [ -d %s ]; then for f in %s/*; do [ -f "$f" ] && source "$f"; done; fi`, dir, dir)
	}
}

// Shell wrapper for `wayu`: after a successful (non dry-run) `wayu path add
// <dir>`, prepend the *absolute* dir to the current shell's PATH. core.{ext}
// is already regenerated by the CLI itself, so no extra build is needed.
// Shared by zsh and bash; only the absolutising line differs.
WAYU_WRAPPER_HEAD :: `wayu() {
  command wayu "$@"
  local _wayu_exit=$?
  [ "$_wayu_exit" -eq 0 ] || return "$_wayu_exit"
  local _wayu_arg _wayu_cmd="" _wayu_act="" _wayu_dir="" _wayu_skip=0
  for _wayu_arg in "$@"; do
    if [ "$_wayu_skip" -eq 1 ]; then _wayu_skip=0; continue; fi
    case "$_wayu_arg" in
      -n|--dry-run) return 0 ;;
      --shell) _wayu_skip=1 ;;
      -*) ;;
      *)
        if [ -z "$_wayu_cmd" ]; then _wayu_cmd="$_wayu_arg"
        elif [ -z "$_wayu_act" ]; then _wayu_act="$_wayu_arg"
        elif [ -z "$_wayu_dir" ]; then _wayu_dir="$_wayu_arg"
        fi ;;
    esac
  done
  [ "$_wayu_cmd" = "path" ] && [ "$_wayu_act" = "add" ] && [ -n "$_wayu_dir" ] || return 0
  [ -d "$_wayu_dir" ] || return 0
`

WAYU_WRAPPER_ABS_ZSH :: `  _wayu_dir="${_wayu_dir:A}"
`

WAYU_WRAPPER_ABS_BASH :: `  _wayu_dir="$(cd -- "$_wayu_dir" 2>/dev/null && pwd -P)" || return 0
`

WAYU_WRAPPER_TAIL :: `  case ":$PATH:" in
    *":$_wayu_dir:"*) ;;
    *) export PATH="$_wayu_dir:$PATH" ;;
  esac
  return 0
}
`

// Core: Only what's needed for the prompt to appear (< 10ms).
// zsh and bash share the structure; every zsh-only construct (fpath,
// compinit, add-zsh-hook prompt, zsh plugins, `[[ -o login ]]`) is gated so
// core.bash stays valid bash.
generate_core_init_v2 :: proc() {
	is_zsh := wayu.shell == .ZSH
	shell_ext := get_shell_extension(wayu.shell)
	path := fmt.aprintf("%s/core.%s", wayu.data, shell_ext)
	defer delete(path)

	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	fmt.sbprintln(&builder, get_shebang(wayu.shell))
	fmt.sbprintfln(&builder, "# core.%s - ESSENTIAL (< 10ms)", shell_ext)
	fmt.sbprintln(&builder, "# Auto-generated by wayu build")
	fmt.sbprintln(&builder)

	// PATH read dynamically from [paths] in wayu.toml (file order = priority)
	fmt.sbprintln(&builder, "# === PATH ===")
	if !emit_path_export(&builder) {
		emit_source_if_exists(&builder, fmt.tprintf("%s/path.%s", wayu.data, shell_ext))
	}

	fmt.sbprintln(&builder, "# Deduplicate PATH (preserve order, remove duplicates)")
	if is_zsh {
		fmt.sbprintln(&builder, "typeset -U path PATH")
	} else {
		fmt.sbprintln(&builder, `_wayu_dedup_path() {`)
		fmt.sbprintln(&builder, `  local IFS=':' _wayu_p _wayu_new=""`)
		fmt.sbprintln(&builder, `  for _wayu_p in $PATH; do`)
		fmt.sbprintln(&builder, `    [ -n "$_wayu_p" ] || continue`)
		fmt.sbprintln(&builder, `    case ":$_wayu_new:" in *":$_wayu_p:"*) ;; *) _wayu_new="${_wayu_new:+$_wayu_new:}$_wayu_p" ;; esac`)
		fmt.sbprintln(&builder, `  done`)
		fmt.sbprintln(&builder, `  export PATH="$_wayu_new"`)
		fmt.sbprintln(&builder, `}`)
		fmt.sbprintln(&builder, `_wayu_dedup_path`)
		fmt.sbprintln(&builder, `unset -f _wayu_dedup_path`)
	}
	fmt.sbprintln(&builder)

	fmt.sbprintln(&builder, "# === Environment (from wayu.toml [env]) ===")
	emit_env_exports(&builder)
	fmt.sbprintln(&builder)

	fmt.sbprintln(&builder, "# === Aliases (from wayu.toml [aliases]) ===")
	emit_alias_definitions(&builder)
	fmt.sbprintln(&builder)

	fmt.sbprintln(&builder, "# === wayu shell wrapper ===")
	fmt.sbprint(&builder, WAYU_WRAPPER_HEAD)
	fmt.sbprint(&builder, WAYU_WRAPPER_ABS_ZSH if is_zsh else WAYU_WRAPPER_ABS_BASH)
	fmt.sbprint(&builder, WAYU_WRAPPER_TAIL)
	fmt.sbprintln(&builder)

	completions_dir := fmt.tprintf("%s/completions", wayu.data)
	fmt.sbprintln(&builder, "# === Completions ===")
	if is_zsh {
		fmt.sbprintfln(&builder, "fpath=(%s $fpath)", shell_double_quote_literal(completions_dir, context.temp_allocator))
		fmt.sbprintln(&builder, "autoload -Uz compinit && compinit -C")
	} else {
		q := shell_double_quote_literal(completions_dir, context.temp_allocator)
		fmt.sbprintfln(&builder, `if [ -d %s ]; then for f in %s/*.bash-completion; do [ -f "$f" ] && source "$f"; done; fi`, q, q)
	}
	fmt.sbprintln(&builder)

	// Custom shell functions (user-authored, loaded immediately so they are
	// available in interactive and non-interactive shells alike).
	fmt.sbprintln(&builder, "# === Functions ===")
	emit_functions_loader(&builder)
	fmt.sbprintln(&builder)

	// User configuration from config.{ext}
	config_user := fmt.aprintf("%s/config.%s", wayu.config, shell_ext)
	defer delete(config_user)
	if os.exists(config_user) {
		content, ok := safe_read_file(config_user)
		if ok {
			defer delete(content)
			if len(content) > 0 {
				fmt.sbprintfln(&builder, "# === User configuration (from config.%s) ===", shell_ext)
				fmt.sbprintln(&builder, string(content))
				fmt.sbprintln(&builder)
			}
		}
	}

	fmt.sbprintln(&builder, "# === Load helpers ===")
	helpers_q := shell_double_quote_literal(runtime_file("helpers"), context.temp_allocator)
	fmt.sbprintfln(&builder, "source %s 2>/dev/null || true", helpers_q)
	fmt.sbprintln(&builder)

	// Eager tools - loaded immediately in core (e.g. keybinding tools like atuin).
	// Only `evalcache`-kind tools may be eager; other recipes are always deferred.
	tools := read_wayu_toml_tools()
	defer {
		for &t in tools { destroy_tool_entry(&t) }
		delete(tools)
	}

	eager_count := 0
	for t in tools {
		if t.eager && !t.login_only && tool_kind_is_evalcache(t.kind) { eager_count += 1 }
	}
	if eager_count > 0 {
		fmt.sbprintln(&builder, "# === Tools (eager - keybindings, immediate) ===")
		for t in tools {
			if !t.eager || t.login_only { continue }
			if !tool_kind_is_evalcache(t.kind) { continue }
			emit_evalcache_call(&builder, t)
		}
		fmt.sbprintln(&builder)
	}

	// Prompt: native wayu prompt is zsh-only (prompt escapes, zle, hooks).
	if is_zsh {
		toml_data, toml_ok := get_cached_toml_content()
		if toml_ok {
			fmt.sbprintln(&builder, "# === Prompt (wayu native, interactive) ===")
			prompt_cfg := parse_full_prompt_config(toml_data)
			defer destroy_full_prompt_config(&prompt_cfg)
			base_prompt := generate_full_prompt(prompt_cfg)
			defer delete(base_prompt)

			interactive_cfg := parse_interactive_config(toml_data)
			interactive_cfg.contexts = &prompt_cfg
			interactive_code := generate_interactive_prompt(base_prompt, interactive_cfg)
			defer delete(interactive_code)

			fmt.sbprint(&builder, interactive_code)
			fmt.sbprintln(&builder)
		}
	}

	// Plugins. plugins.{ext} is the loader written by `wayu plugin add`;
	// the hard-coded zsh-autosuggestions / zsh-syntax-highlighting lines are
	// only a fallback when plugins.zsh didn't already load them, and
	// syntax-highlighting is sourced last (after prompt widgets exist).
	fmt.sbprintln(&builder, "# === Plugins ===")
	emit_source_if_exists(&builder, runtime_file("plugins"))
	if is_zsh {
		plugins_dir := fmt.tprintf("%s/plugins", wayu.data)
		as_q := shell_double_quote_literal(fmt.tprintf("%s/zsh-autosuggestions/zsh-autosuggestions.zsh", plugins_dir), context.temp_allocator)
		sh_q := shell_double_quote_literal(fmt.tprintf("%s/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh", plugins_dir), context.temp_allocator)
		fmt.sbprintfln(&builder, "if (( ! ${{+functions[_zsh_autosuggest_start]}} )) && [ -f %s ]; then source %s; fi", as_q, as_q)
		emit_source_if_exists(&builder, fmt.tprintf("%s/config.zsh", plugins_dir))
		fmt.sbprintfln(&builder, "if (( ! ${{+functions[_zsh_highlight]}} )) && [ -f %s ]; then source %s; fi", sh_q, sh_q)
	}
	fmt.sbprintln(&builder)

	// Source lazy init directly (tools, extra config).
	// Previously this used zsh-defer but the home-grown implementation
	// conflicted with TRAPUSR1 (async rprompt) and silently failed,
	// leaving tools like zoxide uninitialised.
	fmt.sbprintln(&builder, "# === Lazy init (tools, extra config) ===")
	fmt.sbprintfln(&builder, "source %s", shell_double_quote_literal(runtime_file("lazy"), context.temp_allocator))
	fmt.sbprintln(&builder)

	// Login-shell-only tools (if any are configured)
	login_count := 0
	for t in tools {
		if t.login_only { login_count += 1 }
	}
	if login_count > 0 {
		login_q := shell_double_quote_literal(runtime_file("login"), context.temp_allocator)
		fmt.sbprintln(&builder, "# === Login shell only ===")
		if is_zsh {
			fmt.sbprintfln(&builder, "if [[ -o login ]] && [ -f %s ]; then source %s; fi", login_q, login_q)
		} else {
			fmt.sbprintfln(&builder, "if shopt -q login_shell && [ -f %s ]; then source %s; fi", login_q, login_q)
		}
		fmt.sbprintln(&builder)
	}

	content := strings.to_string(builder)
	write_init_file(path, content)
	zcompile_file(path)
}

// Lazy: tools (deferred recipes) + user escape hatches (tools/extra).
// This is the ONLY place tools.{ext} and extra.{ext} are sourced for
// zsh/bash — init.{ext} no longer sources them a second time.
generate_lazy_init_v2 :: proc() {
	shell_ext := get_shell_extension(wayu.shell)
	path := fmt.aprintf("%s/lazy.%s", wayu.data, shell_ext)
	defer delete(path)

	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	fmt.sbprintln(&builder, get_shebang(wayu.shell))
	fmt.sbprintfln(&builder, "# lazy.%s - deferred tools + user escape hatches", shell_ext)
	fmt.sbprintln(&builder)

	// Deferred tools (non-eager) from wayu.toml [tools].
	// Includes evalcache (default) plus heavy lazy recipes: nvm, conda, lazy.
	tools := read_wayu_toml_tools()
	defer {
		for &t in tools { destroy_tool_entry(&t) }
		delete(tools)
	}

	// Anything *not* handled in core (eager evalcache) is deferred here.
	// Counter must mirror the emit predicate so the header doesn't appear
	// orphaned (or vanish when an unusual eager non-evalcache slips in).
	deferred_count := 0
	for t in tools {
		if t.login_only { continue }
		if t.eager && tool_kind_is_evalcache(t.kind) { continue }
		deferred_count += 1
	}
	if deferred_count > 0 {
		fmt.sbprintln(&builder, "# === Tools (deferred) ===")
		for t in tools {
			if t.login_only { continue }
			if t.eager && tool_kind_is_evalcache(t.kind) { continue }
			emit_tool_recipe(&builder, t)
		}
		fmt.sbprintln(&builder)
	}

	// User escape hatch: tools.{ext} handles tool init that wayu doesn't ship
	// a recipe for. Sourced here (not just login) so non-login shells -
	// Ghostty / Zellij / tmux panes - also pick up user lazy loaders.
	fmt.sbprintfln(&builder, "# === User tools.%s (escape hatch for unrecognised tools) ===", shell_ext)
	emit_source_if_exists(&builder, fmt.tprintf("%s/tools.%s", wayu.config, shell_ext))
	fmt.sbprintln(&builder)

	fmt.sbprintln(&builder, "# === Extra config ===")
	emit_source_if_exists(&builder, fmt.tprintf("%s/extra.%s", wayu.config, shell_ext))
	fmt.sbprintln(&builder)

	content := strings.to_string(builder)
	write_init_file(path, content)
	zcompile_file(path)
}

// Login: Login-shell-only tools from wayu.toml [tools] with login_only = true.
// Only generates the file when there are login-only tools configured.
generate_login_init_v2 :: proc() {
	shell_ext := get_shell_extension(wayu.shell)
	path := fmt.aprintf("%s/login.%s", wayu.data, shell_ext)
	defer delete(path)

	tools := read_wayu_toml_tools()
	defer {
		for &t in tools { destroy_tool_entry(&t) }
		delete(tools)
	}

	login_count := 0
	for t in tools {
		if t.login_only { login_count += 1 }
	}
	if login_count == 0 {
		// No login-only tools — remove stale login file if it exists
		if os.exists(path) { os.remove(path) }
		return
	}

	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	fmt.sbprintln(&builder, get_shebang(wayu.shell))
	fmt.sbprintfln(&builder, "# login.%s - LOGIN SHELL ONLY", shell_ext)
	fmt.sbprintln(&builder, "# Tools marked login_only=true in wayu.toml [tools]")
	fmt.sbprintln(&builder)
	fmt.sbprintln(&builder, "# === Login-only tools ===")
	for t in tools {
		if !t.login_only { continue }
		emit_tool_recipe(&builder, t)
	}
	fmt.sbprintln(&builder)

	content := strings.to_string(builder)
	write_init_file(path, content)
	zcompile_file(path)
}

// evalcache: shared by zsh and bash. The cache key includes the sanitised
// args, so `zoxide init zsh` and `zoxide init zsh --cmd cd` don't share
// (and serve) a stale cache when args change in wayu.toml.
HELPER_EVALCACHE :: `# ============================================================================
# EVALCACHE - Cache eval output, regenerate if binary changed or args differ
# ============================================================================
_wayu_evalcache() {
  local cmd="$1"
  shift
  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/wayu/evalcache"
  local key="${cmd//[^A-Za-z0-9._-]/_}"
  if [ "$#" -gt 0 ]; then
    local args="$*"
    key="${key}__${args//[^A-Za-z0-9._-]/_}"
  fi
  key="${key:0:200}"
  local cache_file="$cache_dir/$key"
  local bin_path
  bin_path="$(command -v "$cmd" 2>/dev/null)"

  # Skip silently if the tool isn't installed
  [ -z "$bin_path" ] && return 0

  [ -d "$cache_dir" ] || mkdir -p "$cache_dir"

  # Regenerate if: cache doesn't exist, is empty, or binary is newer than cache
  if [ ! -s "$cache_file" ] || [ "$bin_path" -nt "$cache_file" ]; then
    local tmp_file="${cache_file}.tmp.$$"
    if "$cmd" "$@" > "$tmp_file" 2>/dev/null && [ -s "$tmp_file" ]; then
      mv -f "$tmp_file" "$cache_file"
    else
      # Failed or empty output - drop the tmpfile, leave any prior good cache alone
      rm -f "$tmp_file"
      [ -s "$cache_file" ] || return 1
    fi
  fi

  source "$cache_file"
}
`

// zsh-only helpers: built-in zsh-defer + the single USR1 handler shared with
// the async prompt (prompt.odin defines _wayu_async_on_usr1). Previously the
// prompt's TRAPUSR1 replaced this file's `trap ... USR1`, so the defer queue
// only advanced one item per prompt.
HELPER_ZSH_DEFER :: `
# ============================================================================
# ZSH-DEFER BUILT-IN - Implementation without external plugin
# Defers execution until the prompt is ready and idle
# ============================================================================

# Deferred command queue
(( ${+_wayu_defer_queue} )) || typeset -ga _wayu_defer_queue

zsh-defer() {
  local delay=0
  while [[ "$1" == -* ]]; do
    case "$1" in
      -t|--time) delay="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  local cmd="$*"
  [[ -n "$cmd" ]] && _wayu_defer_queue+=("$cmd:$delay")
  return 0
}

# Process one deferred command
_wayu_defer_process_one() {
  (( ${#_wayu_defer_queue} )) || return 0
  local item="${_wayu_defer_queue[1]}"
  local cmd="${item%:*}"
  local delay="${item##*:}"
  shift _wayu_defer_queue
  if [[ "$delay" != "0" && -n "$delay" ]]; then
    (sleep "$delay" && eval "$cmd") &!
  else
    eval "$cmd" 2>/dev/null
  fi
  return 0
}

# Ask ourselves (via USR1) to continue draining the queue shortly.
_wayu_defer_kick() {
  ( sleep 0.1 && kill -USR1 $$ 2>/dev/null ) &!
}

# precmd hook - runs deferred commands after the first prompt
_wayu_defer_precmd() {
  (( ${#_wayu_defer_queue} )) || return 0
  _wayu_defer_process_one
  (( ${#_wayu_defer_queue} )) && _wayu_defer_kick
  return 0
}

# Single USR1 handler: drains zsh-defer AND forwards to the async prompt.
TRAPUSR1() {
  if (( ${#_wayu_defer_queue} )); then
    _wayu_defer_process_one
    (( ${#_wayu_defer_queue} )) && _wayu_defer_kick
  fi
  (( ${+functions[_wayu_async_on_usr1]} )) && _wayu_async_on_usr1
  return 0
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd _wayu_defer_precmd

# ============================================================================
# WAYU COMPILE - Compile init files to bytecode (manual command)
# ============================================================================
wayu_compile() {
  local f
  echo "Compiling init files to bytecode..."
  for f in core helpers lazy login plugins; do
    [[ -f "${WAYU_DATA_DIR:-$HOME/.config/wayu}/$f.zsh" ]] || continue
    zcompile "${WAYU_DATA_DIR:-$HOME/.config/wayu}/$f.zsh" 2>/dev/null && echo "✓ $f.zsh"
  done
  echo "Done. Loading 2-3x faster."
}
`

// Helpers: Support functions (evalcache; zsh additionally gets zsh-defer).
generate_helpers_init_v2 :: proc() {
	shell_ext := get_shell_extension(wayu.shell)
	path := fmt.aprintf("%s/helpers.%s", wayu.data, shell_ext)
	defer delete(path)

	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	fmt.sbprintfln(&builder, "# helpers.%s - Support functions for wayu", shell_ext)
	fmt.sbprintln(&builder)
	fmt.sbprint(&builder, HELPER_EVALCACHE)
	if wayu.shell == .ZSH {
		fmt.sbprint(&builder, HELPER_ZSH_DEFER)
	}

	write_init_file(path, strings.to_string(builder))
	zcompile_file(path)
}

// ============================================================================
// Minimal TOML line readers for [paths] / [env] / [aliases]
// ============================================================================

// If `trimmed` is a table header (`[name]`, optionally followed by a
// comment), return the table name.
toml_line_section :: proc(trimmed: string) -> (name: string, is_header: bool) {
	if !strings.has_prefix(trimmed, "[") { return "", false }
	end := strings.index_byte(trimmed, ']')
	if end < 0 { return strings.trim_space(trimmed[1:]), true }
	return strings.trim_space(trimmed[1:end]), true
}

// Parse the right-hand side of a simple `key = value` TOML line. Handles
// basic strings ("..." with escapes), literal strings ('...'), and bare
// values, each optionally followed by an inline `# comment`. Exactly one
// matching quote pair is removed, so `'%h'` inside a "..." value keeps its
// quotes, and "" yields an empty (but valid) value. Returns an owned string.
parse_toml_line_value :: proc(raw: string) -> (value: string, ok: bool) {
	s := strings.trim_space(raw)
	if len(s) == 0 { return "", false }
	switch s[0] {
	case '"':
		if strings.has_prefix(s, `"""`) { return "", false } // multi-line: unsupported here
		i := 1
		for i < len(s) {
			if s[i] == '\\' { i += 2; continue }
			if s[i] == '"' { break }
			i += 1
		}
		if i >= len(s) { return "", false } // unterminated
		rest := strings.trim_space(s[i+1:])
		if len(rest) > 0 && rest[0] != '#' { return "", false }
		return unescape_toml_string(s[1:i]), true
	case '\'':
		if strings.has_prefix(s, "'''") { return "", false }
		end := strings.index_byte(s[1:], '\'')
		if end < 0 { return "", false }
		end += 1
		rest := strings.trim_space(s[end+1:])
		if len(rest) > 0 && rest[0] != '#' { return "", false }
		return strings.clone(s[1:end]), true
	case:
		v := s
		if hash := strings.index_byte(v, '#'); hash >= 0 { v = strings.trim_space(v[:hash]) }
		return strings.clone(v), true
	}
}

TomlKV :: struct { key, value: string }

// Read `key = value` pairs of one top-level table, in file order.
// Caller owns keys/values (destroy with destroy_toml_kvs).
read_toml_section_kvs :: proc(section: string) -> [dynamic]TomlKV {
	out := make([dynamic]TomlKV)
	content_str, ok := get_cached_toml_content()
	if !ok { return out }

	it := make_line_iter(content_str)
	in_section := false
	for line in line_iter_next(&it) {
		trimmed := strings.trim_space(line)
		if name, is_header := toml_line_section(trimmed); is_header {
			in_section = name == section
			continue
		}
		if !in_section { continue }
		if len(trimmed) == 0 || trimmed[0] == '#' { continue }

		eq := strings.index_byte(trimmed, '=')
		if eq < 1 { continue }
		key := strings.trim_space(trimmed[:eq])
		if len(key) >= 2 && ((key[0] == '"' && key[len(key)-1] == '"') || (key[0] == '\'' && key[len(key)-1] == '\'')) {
			key = key[1:len(key)-1]
		}
		if len(key) == 0 { continue }
		value, vok := parse_toml_line_value(trimmed[eq+1:])
		if !vok { continue }
		append(&out, TomlKV{key = strings.clone(key), value = value})
	}
	return out
}

destroy_toml_kvs :: proc(kvs: ^[dynamic]TomlKV) {
	for kv in kvs { delete(kv.key); delete(kv.value) }
	delete(kvs^)
}

// Expand a [paths] value to an absolute path: leading `~` → $HOME, then
// $VAR / ${VAR} from the environment. Caller owns the result.
expand_toml_path_value :: proc(val: string) -> string {
	v := val
	tilde := ""
	if v == "~" || strings.has_prefix(v, "~/") {
		home := os.get_env("HOME", context.temp_allocator)
		tilde = strings.concatenate({home, v[1:]})
		v = tilde
	}
	defer if len(tilde) > 0 { delete(tilde) }
	return expand_env_vars(v)
}

// Read the [paths] table from wayu.toml in FILE ORDER (the order is the
// PATH priority). Values are expanded ($HOME, ~/, $VAR) before the existence
// check, duplicates are dropped, and non-existent directories are excluded
// with a warning.
read_wayu_toml_paths :: proc() -> [dynamic]string {
	kvs := read_toml_section_kvs("paths")
	defer destroy_toml_kvs(&kvs)

	paths := make([dynamic]string)
	for kv in kvs {
		if len(kv.value) == 0 { continue }
		expanded := expand_toml_path_value(kv.value)
		duplicate := false
		for p in paths {
			if p == expanded { duplicate = true; break }
		}
		if duplicate {
			delete(expanded)
			continue
		}
		if os.exists(expanded) {
			append(&paths, expanded)
		} else {
			fmt.eprintf("%s[wayu]%s %s⚠%s %spath does not exist, excluding from path: %s%s%s%s\n", VIBRANT_PRIMARY, RESET_CODE, get_warning(), RESET_CODE, BRIGHT_WHITE, RESET_CODE, BRIGHT_CYAN, kv.value, RESET_CODE)
			delete(expanded)
		}
	}
	return paths
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
	name:          string,    // recipe label; for evalcache also the binary to invoke
	kind:          string,    // "evalcache" | "nvm" | "conda" | "lazy"
	args:          string,    // evalcache: extra args (e.g. "init zsh")
	eager:         bool,      // evalcache: load in core instead of lazy
	login_only:    bool,      // only load in login shells (login.zsh)
	init_script:   string,    // lazy: path sourced on first hook invocation
	hook_commands: []string,  // lazy: commands wrapped to trigger load
}

destroy_tool_entry :: proc(t: ^ToolEntry) {
	if len(t.name)        > 0 { delete(t.name) }
	if len(t.kind)        > 0 { delete(t.kind) }
	if len(t.args)        > 0 { delete(t.args) }
	if len(t.init_script) > 0 { delete(t.init_script) }
	for s in t.hook_commands { delete(s) }
	if len(t.hook_commands) > 0 { delete(t.hook_commands) }
}

// Return the text of one top-level table (header line included, sub-tables
// like [tools.x] too), or "" when absent. Caller deletes the result.
extract_toml_section :: proc(content, section: string) -> string {
	sb := strings.builder_make()
	it := make_line_iter(content)
	in_section := false
	for line in line_iter_next(&it) {
		trimmed := strings.trim_space(line)
		if name, is_header := toml_line_section(trimmed); is_header {
			name = strings.trim(name, "[]")
			in_section = name == section || strings.has_prefix(name, fmt.tprintf("%s.", section))
		}
		if in_section {
			strings.write_string(&sb, line)
			strings.write_byte(&sb, '\n')
		}
	}
	if strings.builder_len(sb) == 0 {
		strings.builder_destroy(&sb)
		return ""
	}
	return strings.to_string(sb)
}

// Caller must destroy_tool_entry each element + `delete` the dynamic array.
read_wayu_toml_tools :: proc() -> [dynamic]ToolEntry {
	content_str, ok := get_cached_toml_content()
	if !ok { return make([dynamic]ToolEntry) }

	// Only the [tools] table matters here. Parsing the whole file into the
	// fixed-size arena (previously capped at 512KB) ran out of memory and
	// segfaulted on large configs (thousands of aliases). Feed the parser
	// just the [tools] section and size the arena proportionally, uncapped.
	tools_src := extract_toml_section(content_str, "tools")
	if len(tools_src) == 0 { return make([dynamic]ToolEntry) }
	defer delete(tools_src)

	// The TOML parser allocates TomlValue structs, maps, and cloned strings
	// inside the arena: 32x the input with a 64KB floor is ample.
	arena_size := max(64 * 1024, len(tools_src) * 32)
	arena_buf := make([]byte, arena_size)
	defer delete(arena_buf)
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf)

	doc, _ := toml_doc_parse_simple(tools_src, &arena)
	tools_val, has := doc.values["tools"]
	if !has || tools_val == nil || tools_val.type != .TABLE {
		return make([dynamic]ToolEntry)
	}

	// Sort by tool name so the generated init files are deterministic
	// run-to-run (Odin map iteration order is undefined).
	names := make([dynamic]string, 0, len(tools_val.table_val))
	defer delete(names)
	for name, val in tools_val.table_val {
		if val == nil || val.type != .TABLE { continue }
		append(&names, name)
	}
	slice.sort(names[:])

	entries := make([dynamic]ToolEntry)
	for name in names {
		append(&entries, tool_entry_from_inline_table(name, tools_val.table_val[name]))
	}
	return entries
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
		for elem in v.arr_val { if elem.type == .STRING { n += 1 } }
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

// `_wayu_evalcache <name> <args>`. Args are intentionally word-split (they
// are the tool's argv, e.g. "init zsh --disable-up-arrow").
emit_evalcache_call :: proc(b: ^strings.Builder, t: ToolEntry) {
	if !is_safe_alias_name(t.name) {
		fmt.sbprintfln(b, "# wayu: invalid tool name %q - skipping", t.name)
		return
	}
	if len(t.args) > 0 {
		fmt.sbprintfln(b, "_wayu_evalcache %s %s", t.name, t.args)
	} else {
		fmt.sbprintfln(b, "_wayu_evalcache %s", t.name)
	}
}

// Emit the deferred init code for a single tool entry.
// Eager evalcache tools are handled in core; this dispatcher runs from
// lazy/login and covers everything else (deferred evalcache + heavy recipes).
emit_tool_recipe :: proc(b: ^strings.Builder, t: ToolEntry) {
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
		fmt.sbprintfln(b, "# wayu: 'lazy' kind for %q needs init_script + hook_commands - skipping", t.name)
		return
	}

	ident  := sanitize_ident(t.name)
	loader := fmt.tprintf("_wayu_lazy_%s_load", ident)
	flag   := fmt.tprintf("_WAYU_LAZY_%s_LOADED", strings.to_upper(ident, context.temp_allocator))

	cmds := make([dynamic]string, 0, len(t.hook_commands), context.temp_allocator)
	for cmd in t.hook_commands {
		if is_safe_alias_name(cmd) {
			append(&cmds, cmd)
		} else {
			fmt.sbprintfln(b, "# wayu: invalid hook command %q for %q - skipping", cmd, t.name)
		}
	}
	if len(cmds) == 0 { return }

	script := shell_double_quote_env(expand_leading_tilde_to_home_var(t.init_script, context.temp_allocator), context.temp_allocator)

	fmt.sbprintfln(b, "# --- recipe: lazy (%s) ---", t.name)
	fmt.sbprint(b, loader)
	fmt.sbprintln(b, "() {")
	fmt.sbprintfln(b, "  [ -n \"$%s\" ] && return 0", flag)
	fmt.sbprintfln(b, "  %s=1", flag)
	fmt.sbprint(b, "  unset -f")
	for cmd in cmds { fmt.sbprintf(b, " %s", cmd) }
	fmt.sbprintln(b, " 2>/dev/null")
	fmt.sbprintfln(b, "  [ -s %s ] && \\. %s", script, script)
	fmt.sbprintln(b, "}")
	for cmd in cmds {
		fmt.sbprint(b, cmd)
		fmt.sbprint(b, "() { ")
		fmt.sbprint(b, loader)
		fmt.sbprint(b, "; ")
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
		case c >= 'a' && c <= 'z',
		     c >= 'A' && c <= 'Z',
		     c >= '0' && c <= '9',
		     c == '_':
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
RECIPE_NVM_ZSH :: `_wayu_setup_nvm_lazy() {
  # Point PATH to NVM's default node (instant, no subprocess).
  local nvm_default_path="$NVM_DIR/alias/default"
  if [[ -f "$nvm_default_path" ]]; then
    local default_version
    default_version="$(<"$nvm_default_path")"
    while [[ -f "$NVM_DIR/alias/$default_version" ]]; do
      default_version="$(<"$NVM_DIR/alias/$default_version")"
    done
    if [[ "$default_version" == "node" ]]; then
      local latest_dir
      latest_dir="$(ls -d "$NVM_DIR/versions/node/"v* 2>/dev/null | sort -V | tail -1)"
      [[ -d "$latest_dir/bin" ]] && export PATH="$latest_dir/bin:$PATH"
    else
      local node_dir
      for node_dir in "$NVM_DIR/versions/node/v${default_version}"*(N); do
        [[ -d "$node_dir/bin" ]] && export PATH="$node_dir/bin:$PATH" && break
      done
    fi
  fi

  _wayu_load_nvm() {
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

  _wayu_run_node_bin() {
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
    eval "$cmd() { _wayu_run_node_bin $cmd \"\$@\" }"
    return $_exit_code
  }

  nvm()      { _wayu_load_nvm; nvm "$@" }
  node()     { _wayu_run_node_bin node "$@" }
  npm()      { _wayu_run_node_bin npm "$@" }
  npx()      { _wayu_run_node_bin npx "$@" }
  corepack() { _wayu_run_node_bin corepack "$@" }

  _wayu_fast_nvmrc() {
    local nvmrc_file=""
    [[ -f ".nvmrc" ]]        && nvmrc_file=".nvmrc"
    [[ -f ".node-version" ]] && nvmrc_file=".node-version"
    [[ -z "$nvmrc_file" ]] && return 1
    local requested
    requested="$(<"$nvmrc_file")"
    requested="${requested#v}"
    requested="${requested## }"
    requested="${requested%% }"
    local match_dir="" node_dir
    for node_dir in "$NVM_DIR/versions/node/"v${requested}*(N); do
      [[ -d "$node_dir/bin" ]] && match_dir="$node_dir"
    done
    if [[ -n "$match_dir" ]]; then
      local -a path_parts new_parts
      path_parts=("${(@s/:/)PATH}")
      local nvm_prefix="$NVM_DIR/versions/node/" p
      for p in "${path_parts[@]}"; do
        [[ "$p" == ${nvm_prefix}* ]] && continue
        new_parts+=("$p")
      done
      export PATH="$match_dir/bin:${(j/:/)new_parts}"
      return 0
    fi
    return 1
  }

  _wayu_chpwd_nvmrc() {
    if [[ -f ".nvmrc" ]] || [[ -f ".node-version" ]]; then
      _wayu_fast_nvmrc || { _wayu_load_nvm; nvm use --silent >/dev/null 2>&1 }
    fi
  }
  autoload -Uz add-zsh-hook 2>/dev/null
  add-zsh-hook chpwd _wayu_chpwd_nvmrc 2>/dev/null
  _wayu_fast_nvmrc
}
if [ -d "${NVM_DIR:=$HOME/.nvm}" ]; then export NVM_DIR; _wayu_setup_nvm_lazy; fi`

// Lazy NVM recipe (bash). Same idea, bash syntax: default node goes on PATH
// immediately; only `nvm` itself is wrapped (node/npm resolve via PATH).
RECIPE_NVM_BASH :: `_wayu_setup_nvm_lazy() {
  local nvm_default_path="$NVM_DIR/alias/default" default_version node_dir
  if [ -f "$nvm_default_path" ]; then
    default_version="$(<"$nvm_default_path")"
    while [ -f "$NVM_DIR/alias/$default_version" ]; do
      default_version="$(<"$NVM_DIR/alias/$default_version")"
    done
    if [ "$default_version" = "node" ]; then
      node_dir="$(ls -d "$NVM_DIR/versions/node/"v* 2>/dev/null | sort -V | tail -1)"
      [ -d "$node_dir/bin" ] && export PATH="$node_dir/bin:$PATH"
    else
      for node_dir in "$NVM_DIR/versions/node/v${default_version}"*; do
        [ -d "$node_dir/bin" ] && export PATH="$node_dir/bin:$PATH" && break
      done
    fi
  fi
}
_wayu_load_nvm() {
  [ -n "$_WAYU_NVM_LOADED" ] && return 0
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
nvm() { _wayu_load_nvm; nvm "$@"; }
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

  conda()  { _wayu_load_conda; conda "$@" }
  mamba()  { _wayu_load_conda; mamba "$@" }
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
    [ -n "$_WAYU_CONDA_LOADED" ] && return 0
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

  conda()  { _wayu_load_conda; conda "$@"; }
  mamba()  { _wayu_load_conda; mamba "$@"; }
}
_wayu_setup_conda_lazy`

// ============================================================================
// Env / alias entries from wayu.toml
// ============================================================================

EnvEntry :: struct {
	name: string,
	value: string,
}

// Read [env] in FILE ORDER so later values can reference earlier ones
// (GOBIN = "$GOPATH/bin" after GOPATH). Empty "" values are kept.
read_wayu_toml_env :: proc() -> [dynamic]EnvEntry {
	kvs := read_toml_section_kvs("env")
	defer delete(kvs)
	entries := make([dynamic]EnvEntry, 0, len(kvs))
	for kv in kvs {
		append(&entries, EnvEntry{name = kv.key, value = kv.value}) // ownership moves
	}
	return entries
}

// Read the [aliases] table from wayu.toml. Returns entries sorted by name
// for deterministic output. AliasEntry is defined in colors.odin.
read_wayu_toml_aliases :: proc() -> [dynamic]AliasEntry {
	kvs := read_toml_section_kvs("aliases")
	defer delete(kvs)
	entries := make([dynamic]AliasEntry, 0, len(kvs))
	for kv in kvs {
		append(&entries, AliasEntry{name = kv.key, command = kv.value}) // ownership moves
	}
	slice.sort_by(entries[:], proc(a, b: AliasEntry) -> bool { return a.name < b.name })
	return entries
}

// ============================================================================
// Fish core generator
// ============================================================================
//
// Fish syntax is incompatible with bash/zsh, so we emit a dedicated
// core.fish rather than sharing generate_core_init_v2. Keep it simple:
// PATH, env, aliases, plugin runtime, user config.fish. No zsh-defer/lazy.
generate_core_init_fish :: proc() {
	path := fmt.aprintf("%s/core.fish", wayu.data)
	defer delete(path)

	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	fmt.sbprintln(&builder, "#!/usr/bin/env fish")
	fmt.sbprintln(&builder, "# core.fish - generated by wayu")
	fmt.sbprintln(&builder)

	// PATH from [paths] (already expanded to absolute literals). Iterate in
	// reverse so the first [paths] entry ends up first on PATH.
	fmt.sbprintln(&builder, "# === PATH ===")
	toml_paths := read_wayu_toml_paths()
	defer {
		for p in toml_paths { delete(p) }
		delete(toml_paths)
	}
	#reverse for p in toml_paths {
		q := escape_fish_string(p, context.temp_allocator)
		fmt.sbprintfln(&builder, `if test -d %s; and not contains -- %s $PATH`, q, q)
		fmt.sbprintfln(&builder, `    set -gx PATH %s $PATH`, q)
		fmt.sbprintln(&builder, "end")
	}
	fmt.sbprintln(&builder)

	// Env from [env]: double-quoted so $VAR expands, `~/` → $HOME/.
	fmt.sbprintln(&builder, "# === Environment (from wayu.toml [env]) ===")
	toml_env := read_wayu_toml_env()
	defer {
		for e in toml_env { delete(e.name); delete(e.value) }
		delete(toml_env)
	}
	for e in toml_env {
		if !is_shell_var_name(e.name) {
			fmt.sbprintfln(&builder, "# wayu: skipping invalid env name %q", e.name)
			continue
		}
		v := expand_leading_tilde_to_home_var(e.value, context.temp_allocator)
		fmt.sbprintfln(&builder, `set -gx %s %s`, e.name, fish_double_quote_env(v, context.temp_allocator))
	}
	fmt.sbprintln(&builder)

	// Aliases from [aliases]: fully literal single-quoted body.
	fmt.sbprintln(&builder, "# === Aliases (from wayu.toml [aliases]) ===")
	toml_aliases := read_wayu_toml_aliases()
	defer {
		for a in toml_aliases { delete(a.name); delete(a.command) }
		delete(toml_aliases)
	}
	for a in toml_aliases {
		if !is_safe_alias_name(a.name) {
			fmt.sbprintfln(&builder, "# wayu: skipping invalid alias name %q", a.name)
			continue
		}
		fmt.sbprintfln(&builder, `alias %s %s`, a.name, escape_fish_string(a.command, context.temp_allocator))
	}
	fmt.sbprintln(&builder)

	// Completions directory
	fmt.sbprintln(&builder, "# === Completions ===")
	fmt.sbprintfln(&builder, `set -p fish_complete_path %s`, escape_fish_string(fmt.tprintf("%s/completions", wayu.data), context.temp_allocator))
	fmt.sbprintln(&builder)

	// Plugin runtime (generated separately by generate_plugins_file)
	plugins_q := escape_fish_string(fmt.tprintf("%s/plugins.fish", wayu.data), context.temp_allocator)
	fmt.sbprintln(&builder, "# === Plugins ===")
	fmt.sbprintfln(&builder, `if test -f %s`, plugins_q)
	fmt.sbprintfln(&builder, `    source %s`, plugins_q)
	fmt.sbprintln(&builder, "end")
	fmt.sbprintln(&builder)

	// User config.fish
	config_fish := fmt.aprintf("%s/config.fish", wayu.config)
	defer delete(config_fish)
	if os.exists(config_fish) {
		content, ok := safe_read_file(config_fish)
		if ok {
			defer delete(content)
			if len(content) > 0 {
				fmt.sbprintln(&builder, "# === User configuration (from config.fish) ===")
				fmt.sbprintln(&builder, string(content))
			}
		}
	}

	content := strings.to_string(builder)
	write_init_file(path, content)
}

// generate_eval_output_optimized generates all optimized init files and
// prints the source command (meant for `eval "$(wayu build eval)"`).
// Under --dry-run nothing is written and only comments are printed.
generate_eval_output_optimized :: proc() {
	generate_optimized_init_all()
	if wayu.dry_run { return }

	core_file := fmt.aprintf("%s/core.%s", wayu.data, get_shell_extension(wayu.shell))
	defer delete(core_file)

	if wayu.shell == .FISH {
		fmt.printfln("source %s", escape_fish_string(core_file, context.temp_allocator))
	} else {
		fmt.printfln("source %s", shell_double_quote_literal(core_file, context.temp_allocator))
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
	fmt.println("  wayu build profile       # core vs full interactive shell")
	fmt.println()
}
