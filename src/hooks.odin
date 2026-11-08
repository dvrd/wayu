// hooks.odin - Pre/post action hooks for wayu
//
// Allows users to run custom commands before or after wayu operations.
// Useful for logging, notifications, or custom integrations.

package wayu

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

// Hook types
HookType :: enum {
	PRE_PATH_ADD,
	POST_PATH_ADD,
	PRE_PATH_REMOVE,
	POST_PATH_REMOVE,
	PRE_ALIAS_ADD,
	POST_ALIAS_ADD,
	PRE_ALIAS_REMOVE,
	POST_ALIAS_REMOVE,
	PRE_CONSTANT_ADD,
	POST_CONSTANT_ADD,
	PRE_CONSTANT_REMOVE,
	POST_CONSTANT_REMOVE,
	PRE_EXPORT,
	POST_EXPORT,
	PRE_PLUGIN_INSTALL,
	POST_PLUGIN_INSTALL,
}

// Hook configuration
HookConfig :: struct {
	pre_path_add:       string,
	post_path_add:      string,
	pre_path_remove:    string,
	post_path_remove:   string,
	pre_alias_add:      string,
	post_alias_add:     string,
	pre_alias_remove:   string,
	post_alias_remove:  string,
	pre_constant_add:   string,
	post_constant_add:  string,
	pre_constant_remove: string,
	post_constant_remove: string,
	pre_plugin_install: string,
	post_plugin_install: string,
	pre_export:         string,
	post_export:        string,
	// Hooks refused at load (placeholder inside "..."); see hook_config_error.
	invalid:            [dynamic]HookInvalid,
}

// A hooks.conf line whose command puts a placeholder inside "...".
HookInvalid :: struct {
	key:   string, // owned
	line:  int,    // 1-based line in hooks.conf
	token: string, // static: "{path}" / "{name}" / "{value}"
}

// Hook file path
HOOK_CONFIG_FILE :: "hooks.conf"

// HookContext disambiguates the three hook placeholders `{path}`, `{name}`,
// and `{value}`. Previously a single `context_data` string was substituted
// for all three, which broke hook scripts that referenced more than one
// placeholder (e.g. `echo "$NAME = $VALUE"` on a constant hook). Now each
// caller fills in only the placeholders meaningful for its hook type; the
// others stay empty. See thoughts/code_review_2026-04-24.md N2.
HookContext :: struct {
	path:  string,  // for PATH_* hooks: the directory being added/removed
	name:  string,  // for ALIAS/CONSTANT/PLUGIN_* hooks: the entry identifier
	value: string,  // for CONSTANT_* hooks: the value being assigned (optional)
}

// Execute a hook if configured.
//
// Accepts either a `HookContext` for precise placeholder disambiguation, or
// (for backward compatibility) a single positional string used to fill the
// hook's one meaningful placeholder — the convenience shim `execute_hook`
// routes the legacy single-string form through a context whose field is
// chosen based on hook type.
//
// Security: placeholder values are NEVER spliced into the shell text. Each
// placeholder is rewritten into a quoted reference to an environment variable
// (WAYU_HOOK_PATH / WAYU_HOOK_NAME / WAYU_HOOK_VALUE) that is set only for the
// hook's lifetime, so a value like `x; rm -rf ~` stays inert data.
//
// An invalid hooks.conf (placeholder inside "...") fails the operation with
// EXIT_CONFIG before any hook runs. Every write path calls its pre-hook first,
// so a bad post-hook is also caught before anything is written. In the TUI the
// callers check hook_config_error() themselves (no exit from raw mode); here
// invalid hooks are simply not run.
//
// Hooks never run under --dry-run (nothing is actually being changed).
execute_hook_ctx :: proc(hook_type: HookType, ctx: HookContext) {
	if msg, bad := hook_config_error(); bad {
		if wayu.tui_mode do return
		print_error("%s", msg)
		os.exit(EXIT_CONFIG)
	}
	if wayu.dry_run do return

	hook_cmd := get_hook_command(hook_type)
	defer delete(hook_cmd)
	if len(hook_cmd) == 0 {
		return
	}

	cmd := hook_render_command(hook_cmd)
	defer delete(cmd)

	// Each field defaults to "" so absent placeholders expand to empty rather
	// than getting conflated with the other fields.
	_ = os.set_env(HOOK_ENV_PATH, ctx.path)
	_ = os.set_env(HOOK_ENV_NAME, ctx.name)
	_ = os.set_env(HOOK_ENV_VALUE, ctx.value)
	defer {
		_ = os.unset_env(HOOK_ENV_PATH)
		_ = os.unset_env(HOOK_ENV_NAME)
		_ = os.unset_env(HOOK_ENV_VALUE)
	}

	// Execute via shell (fire and forget - don't block on output)
	debug("Executing hook: %s", cmd)
	hook_args := []string{"sh", "-c", cmd}
	run_command(hook_args)  // Ignoring return value - hooks are best-effort
}

HOOK_ENV_PATH  :: "WAYU_HOOK_PATH"
HOOK_ENV_NAME  :: "WAYU_HOOK_NAME"
HOOK_ENV_VALUE :: "WAYU_HOOK_VALUE"

// Rewrite `{path}`/`{name}`/`{value}` placeholders in a hook command into
// references to the WAYU_HOOK_* environment variables, quoted for the shell
// context the placeholder appears in:
//   unquoted       {name}  →  "${WAYU_HOOK_NAME}"
//   inside '...'   {name}  →  "${WAYU_HOOK_NAME}"      (left for an inner shell)
//   inside "..."   REFUSED (reported via double_token; the hook is invalid)
// Expansion results are never re-parsed by the shell, so values cannot inject
// syntax. Single-quoted text is usually a script for a nested shell
// (`sh -c '... {path}'`, ssh, eval): splicing the value there (the old
// close-expand-reopen form) let the inner shell execute it (OKAMI-230). The
// reference is instead passed through unexpanded, and the inner shell, which
// inherits WAYU_HOOK_*, expands it quoted. Inside "..." the outer shell
// expands the value and a nested `sh -c "..."` / `eval "..."` then re-parses
// it as code, so such hooks are rejected at load. Caller owns the returned
// string.
hook_render_command :: proc(cmd: string) -> string {
	out, _, _ := hook_render_command_ex(cmd)
	return out
}

// hook_render_command plus whether any placeholder sat inside '...' (shown
// as a hint by `wayu hooks`: there it is NOT substituted by wayu's shell) and
// the first placeholder found inside "..." ("" if none; such a hook is invalid).
hook_render_command_ex :: proc(cmd: string) -> (out: string, single_quoted: bool, double_token: string) {
	Placeholder :: struct { token, env: string }
	placeholders := [3]Placeholder{
		{"{path}", HOOK_ENV_PATH},
		{"{name}", HOOK_ENV_NAME},
		{"{value}", HOOK_ENV_VALUE},
	}

	b := strings.builder_make()
	in_single, in_double := false, false
	i := 0
	outer: for i < len(cmd) {
		c := cmd[i]
		if c == '{' {
			for p in placeholders {
				if !strings.has_prefix(cmd[i:], p.token) { continue }
				ref := strings.concatenate({"${", p.env, "}"}, context.temp_allocator)
				switch {
				case in_single:
					single_quoted = true
					strings.write_string(&b, strings.concatenate({`"`, ref, `"`}, context.temp_allocator))
				case in_double:
					if len(double_token) == 0 { double_token = p.token }
					strings.write_string(&b, ref)
				case:           strings.write_string(&b, strings.concatenate({`"`, ref, `"`}, context.temp_allocator))
				}
				i += len(p.token)
				continue outer
			}
		}
		switch {
		case in_single:
			if c == '\'' { in_single = false }
		case c == '\\' && i + 1 < len(cmd):
			// Escaped char (outside single quotes): copy the pair untouched.
			strings.write_byte(&b, c)
			strings.write_byte(&b, cmd[i+1])
			i += 2
			continue outer
		case in_double:
			if c == '"' { in_double = false }
		case c == '\'':
			in_single = true
		case c == '"':
			in_double = true
		}
		strings.write_byte(&b, c)
		i += 1
	}
	return strings.to_string(b), single_quoted, double_token
}

// First placeholder inside "..." in a hook command, or "" when the command is
// acceptable.
hook_double_quoted_placeholder :: proc(cmd: string) -> string {
	out, _, tok := hook_render_command_ex(cmd)
	delete(out)
	return tok
}

// Describe every refused hook in hooks.conf. bad=false (msg "") when all hooks
// are valid. msg is allocated in the temp allocator.
hook_config_error :: proc() -> (msg: string, bad: bool) {
	config := load_hook_config()
	defer free_hook_config(config)
	if len(config.invalid) == 0 do return "", false

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "invalid %s/%s: placeholder inside \"...\" is refused", wayu.config, HOOK_CONFIG_FILE)
	for inv in config.invalid {
		fmt.sbprintf(&b, "\n  line %d: %s puts %s inside \"...\"", inv.line, inv.key, inv.token)
	}
	strings.write_string(&b, "\n  The shell expands it before a nested sh -c \"...\" / eval \"...\" re-parses")
	strings.write_string(&b, "\n  the text, so the value could run as code. Write the placeholder unquoted")
	strings.write_string(&b, "\n  (echo Adding {path}), inside '...' for an inner shell (sh -c 'echo {path}'),")
	strings.write_string(&b, "\n  or use the env vars: \"$WAYU_HOOK_PATH\" / \"$WAYU_HOOK_NAME\" / \"$WAYU_HOOK_VALUE\".")
	strings.write_string(&b, "\n  No hook ran and nothing was changed.")
	return strings.to_string(b), true
}

// Legacy single-string entry point. Routes to execute_hook_ctx by picking the
// right context field for each hook type.
execute_hook :: proc(hook_type: HookType, context_data: string = "") {
	ctx: HookContext
	#partial switch hook_type {
	case .PRE_PATH_ADD, .POST_PATH_ADD, .PRE_PATH_REMOVE, .POST_PATH_REMOVE:
		ctx.path = context_data
	case .PRE_ALIAS_ADD, .POST_ALIAS_ADD, .PRE_ALIAS_REMOVE, .POST_ALIAS_REMOVE,
	     .PRE_CONSTANT_ADD, .POST_CONSTANT_ADD, .PRE_CONSTANT_REMOVE, .POST_CONSTANT_REMOVE,
	     .PRE_PLUGIN_INSTALL, .POST_PLUGIN_INSTALL:
		ctx.name = context_data
	case .PRE_EXPORT, .POST_EXPORT:
		// No context — just run the command as-is.
	}
	execute_hook_ctx(hook_type, ctx)
}

// Get hook command for a type
get_hook_command :: proc(hook_type: HookType) -> string {
	config := load_hook_config()
	defer free_hook_config(config)

	result := ""
	switch hook_type {
	case .PRE_PATH_ADD:
		result = config.pre_path_add
	case .POST_PATH_ADD:
		result = config.post_path_add
	case .PRE_PATH_REMOVE:
		result = config.pre_path_remove
	case .POST_PATH_REMOVE:
		result = config.post_path_remove
	case .PRE_ALIAS_ADD:
		result = config.pre_alias_add
	case .POST_ALIAS_ADD:
		result = config.post_alias_add
	case .PRE_ALIAS_REMOVE:
		result = config.pre_alias_remove
	case .POST_ALIAS_REMOVE:
		result = config.post_alias_remove
	case .PRE_CONSTANT_ADD:
		result = config.pre_constant_add
	case .POST_CONSTANT_ADD:
		result = config.post_constant_add
	case .PRE_CONSTANT_REMOVE:
		result = config.pre_constant_remove
	case .POST_CONSTANT_REMOVE:
		result = config.post_constant_remove
	case .PRE_EXPORT:
		result = config.pre_export
	case .POST_EXPORT:
		result = config.post_export
	case .PRE_PLUGIN_INSTALL:
		result = config.pre_plugin_install
	case .POST_PLUGIN_INSTALL:
		result = config.post_plugin_install
	}

	// Clone the result before freeing config, so the caller gets a valid string
	cloned := strings.clone(result)
	return cloned
}

// Load hook configuration
load_hook_config :: proc() -> HookConfig {
	config: HookConfig

	hook_path := fmt.aprintf("%s/%s", wayu.config, HOOK_CONFIG_FILE)
	defer delete(hook_path)

	if !os.exists(hook_path) {
		return config
	}

	content, ok := safe_read_file(hook_path)
	if !ok {
		return config
	}
	defer delete(content)

	// Simple parsing: one hook per line
	lines := strings.split(string(content), "\n")
	defer delete(lines)

	for &line, line_idx in lines {
		line = strings.trim_space(line)
		if len(line) == 0 || strings.has_prefix(line, "#") {
			continue
		}

		parts := strings.split_n(line, "=", 2, context.temp_allocator)

		if len(parts) != 2 {
			continue
		}

		key := strings.trim_space(parts[0])
		value := strings.trim_space(parts[1])
		// Remove ONE matching pair of surrounding quotes (not every quote
		// char at either end, which would eat a trailing `'` of the command).
		if len(value) >= 2 && value[0] == value[len(value)-1] && (value[0] == '"' || value[0] == '\'') {
			value = value[1:len(value)-1]
		}

		switch key {
		case "pre_path_add", "post_path_add", "pre_path_remove", "post_path_remove",
		     "pre_alias_add", "post_alias_add", "pre_alias_remove", "post_alias_remove",
		     "pre_constant_add", "post_constant_add", "pre_constant_remove", "post_constant_remove",
		     "pre_plugin_install", "post_plugin_install", "pre_export", "post_export":
			if tok := hook_double_quoted_placeholder(value); len(tok) > 0 {
				append(&config.invalid, HookInvalid{key = strings.clone(key), line = line_idx + 1, token = tok})
			}
		}

		switch key {
		case "pre_path_add":
			config.pre_path_add = strings.clone(value)
		case "post_path_add":
			config.post_path_add = strings.clone(value)
		case "pre_path_remove":
			config.pre_path_remove = strings.clone(value)
		case "post_path_remove":
			config.post_path_remove = strings.clone(value)
		case "pre_alias_add":
			config.pre_alias_add = strings.clone(value)
		case "post_alias_add":
			config.post_alias_add = strings.clone(value)
		case "pre_alias_remove":
			config.pre_alias_remove = strings.clone(value)
		case "post_alias_remove":
			config.post_alias_remove = strings.clone(value)
		case "pre_constant_add":
			config.pre_constant_add = strings.clone(value)
		case "post_constant_add":
			config.post_constant_add = strings.clone(value)
		case "pre_constant_remove":
			config.pre_constant_remove = strings.clone(value)
		case "post_constant_remove":
			config.post_constant_remove = strings.clone(value)
		case "pre_plugin_install":
			config.pre_plugin_install = strings.clone(value)
		case "post_plugin_install":
			config.post_plugin_install = strings.clone(value)
		case "pre_export":
			config.pre_export = strings.clone(value)
		case "post_export":
			config.post_export = strings.clone(value)
		}
	}

	return config
}

// Free hook config
free_hook_config :: proc(config: HookConfig) {
	delete(config.pre_path_add)
	delete(config.post_path_add)
	delete(config.pre_path_remove)
	delete(config.post_path_remove)
	delete(config.pre_alias_add)
	delete(config.post_alias_add)
	delete(config.pre_alias_remove)
	delete(config.post_alias_remove)
	delete(config.pre_constant_add)
	delete(config.post_constant_add)
	delete(config.pre_constant_remove)
	delete(config.post_constant_remove)
	delete(config.pre_plugin_install)
	delete(config.post_plugin_install)
	delete(config.pre_export)
	delete(config.post_export)
	for inv in config.invalid do delete(inv.key)
	delete(config.invalid)
}

// Handle hooks command
handle_hooks_command :: proc(action: Action, args: []string) {
	#partial switch action {
	case .LIST:
		show_hooks_status()
	case .ADD:
		edit_hooks_config()
	case .HELP:
		print_hooks_usage()
	case:
		show_hooks_status()
	}
}

// Show current hooks status
show_hooks_status :: proc() {
	print_header("Configured Hooks", "🪝")
	fmt.println()

	config := load_hook_config()
	defer free_hook_config(config)

	has_hooks := false

	check_and_print :: proc(name: string, cmd: string, has_hooks: ^bool, config: ^HookConfig) {
		if len(cmd) > 0 {
			fmt.printfln("  %s%s%s: %s", get_primary(), name, RESET, cmd)
			has_hooks^ = true
			rendered, single, double_tok := hook_render_command_ex(cmd)
			delete(rendered)
			if len(double_tok) > 0 {
				line := 0
				for inv in config.invalid do if inv.key == name { line = inv.line }
				fmt.printfln("    %s✗ INVALID (line %d): %s inside \"...\" is refused; this hook never runs and wayu operations exit 78. Write it unquoted, inside '...', or use \"$WAYU_HOOK_*\"%s",
					get_error(), line, double_tok, RESET)
			} else if single {
				fmt.printfln("    %s⚠ placeholder inside '...' is passed to an inner shell as \"$WAYU_HOOK_*\", not substituted here; write it unquoted for direct substitution%s",
					get_warning(), RESET)
			}
		}
	}

	check_and_print("pre_path_add", config.pre_path_add, &has_hooks, &config)
	check_and_print("post_path_add", config.post_path_add, &has_hooks, &config)
	check_and_print("pre_path_remove", config.pre_path_remove, &has_hooks, &config)
	check_and_print("post_path_remove", config.post_path_remove, &has_hooks, &config)
	check_and_print("pre_alias_add", config.pre_alias_add, &has_hooks, &config)
	check_and_print("post_alias_add", config.post_alias_add, &has_hooks, &config)
	check_and_print("pre_alias_remove", config.pre_alias_remove, &has_hooks, &config)
	check_and_print("post_alias_remove", config.post_alias_remove, &has_hooks, &config)
	check_and_print("pre_constant_add", config.pre_constant_add, &has_hooks, &config)
	check_and_print("post_constant_add", config.post_constant_add, &has_hooks, &config)
	check_and_print("pre_constant_remove", config.pre_constant_remove, &has_hooks, &config)
	check_and_print("post_constant_remove", config.post_constant_remove, &has_hooks, &config)
	check_and_print("pre_plugin_install", config.pre_plugin_install, &has_hooks, &config)
	check_and_print("post_plugin_install", config.post_plugin_install, &has_hooks, &config)
	check_and_print("pre_export", config.pre_export, &has_hooks, &config)
	check_and_print("post_export", config.post_export, &has_hooks, &config)

	if !has_hooks {
		fmt.printfln("  %sNo hooks configured%s", get_muted(), RESET)
		fmt.println()
		fmt.println("Hooks let you run custom commands before/after wayu operations.")
		fmt.println()
		fmt.printfln("Edit %s/%s to configure hooks.", wayu.config, HOOK_CONFIG_FILE)
	}

	fmt.println()
	fmt.printfln("%sAvailable placeholders:%s", get_secondary(), RESET)
	fmt.println("  {path}   - The PATH entry being added/removed")
	fmt.println("  {name}   - The alias/constant name")
	fmt.println("  {value}  - The alias command or constant value")
	fmt.println()
	fmt.println("  Values are passed via $WAYU_HOOK_PATH / $WAYU_HOOK_NAME /")
	fmt.println("  $WAYU_HOOK_VALUE and substituted quoted, never as shell code.")
	fmt.println("  Unquoted: substituted. Inside '...' (e.g. a `sh -c '...'` script)")
	fmt.println("  wayu leaves \"$WAYU_HOOK_*\" for the inner shell to expand.")
	fmt.println("  Inside \"...\": REFUSED (a nested sh -c \"...\" / eval \"...\" would")
	fmt.println("  run the value as code); the hook is invalid and wayu exits 78.")
	fmt.println("  Use \"$WAYU_HOOK_*\" directly when you need double quotes.")
	fmt.println("  Hooks are skipped under --dry-run.")
}

// Edit hooks configuration
edit_hooks_config :: proc() {
	hook_path := fmt.aprintf("%s/%s", wayu.config, HOOK_CONFIG_FILE)
	defer delete(hook_path)

	if !os.exists(hook_path) {
		// Create example hooks file
		example := `# wayu hooks configuration
# Uncomment and modify lines to enable hooks

# Path hooks
# Placeholders: {path} {name} {value}. Write them unquoted (wayu quotes the
# value) or inside '...' for an inner shell (sh -c 'echo {path}'). A
# placeholder inside "..." is refused (exit 78): use "$WAYU_HOOK_PATH" /
# "$WAYU_HOOK_NAME" / "$WAYU_HOOK_VALUE" when you need double quotes.

# Path hooks
# pre_path_add = echo Adding {path} >> ~/wayu.log
# post_path_add = hash -r

# Alias hooks
# pre_alias_add = echo New alias: {name}
# post_alias_add = echo "New alias: $WAYU_HOOK_NAME = $WAYU_HOOK_VALUE"

# Plugin hooks
# post_plugin_install = echo Installed {name} >> ~/plugins.log

# Export hooks
# pre_export = "echo 'Generating turbo export...'"
# post_export = "echo 'Export complete'"
`
		write_ok := safe_write_file(hook_path, transmute([]byte)(example))
		if !write_ok {
			print_error("Failed to create hooks config")
			os.exit(EXIT_IOERR)
		}
	}

	// Open in editor.
	//
	// IMPORTANT: do NOT route this through run_command_with_stdin(): that helper
	// redirects stdout+stderr to /dev/null and pipes an empty stdin, which means
	// any TUI editor (vim/nano/helix) renders nothing and appears to hang.
	// Use fork + execvp so the editor inherits our stdin/stdout/stderr directly,
	// mirroring the pattern in edit_toml_config / edit_extra_config (main.odin).
	editor: string
	if e := os.get_env("EDITOR", context.temp_allocator); len(e) > 0 {
		editor = e
	} else if e := os.get_env("VISUAL", context.temp_allocator); len(e) > 0 {
		editor = e
	} else {
		editor = "vi"
	}

	print_info("Opening hooks config in %s...", editor)

	args := []string{editor, hook_path}
	argv := make([dynamic]cstring, len(args) + 1)
	defer {
		for i in 0..<len(args) {
			delete(argv[i])
		}
		delete(argv)
	}
	for arg, i in args {
		argv[i] = strings.clone_to_cstring(arg)
	}
	argv[len(args)] = nil

	pid := posix.fork()
	if pid < 0 {
		print_error("Failed to fork editor process")
		os.exit(EXIT_IOERR)
	}

	if pid == 0 {
		// Child: exec editor with inherited stdio.
		posix.execvp(argv[0], raw_data(argv[:]))
		posix._exit(1)
	}

	// Parent: wait for editor to finish.
	status: c.int = 0
	posix.waitpid(pid, &status, {})
}

// Print hooks usage
print_hooks_usage :: proc() {
	fmt.println()
	fmt.printfln("%swayu hooks - Pre/post action hooks%s", BOLD, RESET)
	fmt.println()
	fmt.printfln("%sUSAGE:%s", get_primary(), RESET)
	fmt.printfln("  wayu hooks              Show configured hooks")
	fmt.printfln("  wayu hooks edit         Edit hooks configuration")
	fmt.printfln("  wayu hooks help         Show this help")
	fmt.println()
	fmt.printfln("%sDESCRIPTION:%s", get_primary(), RESET)
	fmt.println("  Hooks allow running custom commands before/after wayu operations.")
	fmt.println("  Useful for logging, notifications, or custom integrations.")
	fmt.println()
	fmt.printfln("%sCONFIG FILE:%s", get_primary(), RESET)
	fmt.println("  ~/.config/wayu/hooks.conf")
	fmt.println()
	fmt.printfln("%sEXAMPLE HOOKS:%s", get_primary(), RESET)
	fmt.println()
	fmt.println("  # Log PATH changes")
	fmt.println(`  pre_path_add = echo Adding {path} >> ~/wayu.log`)
	fmt.println()
	fmt.println("  # Reload shell after alias changes")
	fmt.println(`  post_alias_add = "source ~/.zshrc"`)
	fmt.println()
	fmt.println("  # Notify when plugins are installed")
	fmt.println(`  post_plugin_install = terminal-notifier -title wayu -message "Installed $WAYU_HOOK_NAME"`)
	fmt.println()
	fmt.printfln("%sPLACEHOLDERS:%s", get_primary(), RESET)
	fmt.println("  {path} {name} {value}: write them unquoted or inside '...' (for an")
	fmt.println("  inner sh -c '...'). Inside \"...\" they are refused (exit 78): a nested")
	fmt.println("  sh -c \"...\" / eval \"...\" would run the value as code. In double")
	fmt.println("  quotes use \"$WAYU_HOOK_PATH\" / \"$WAYU_HOOK_NAME\" / \"$WAYU_HOOK_VALUE\".")
}

// Integration with existing commands - call hooks
// These should be called from the actual add/remove functions

hook_pre_path_add :: proc(path: string) {
	execute_hook(.PRE_PATH_ADD, path)
}

hook_post_path_add :: proc(path: string) {
	execute_hook(.POST_PATH_ADD, path)
}

hook_pre_path_remove :: proc(path: string) {
	execute_hook(.PRE_PATH_REMOVE, path)
}

hook_post_path_remove :: proc(path: string) {
	execute_hook(.POST_PATH_REMOVE, path)
}

hook_pre_export :: proc() {
	execute_hook(.PRE_EXPORT)
}

hook_post_export :: proc() {
	execute_hook(.POST_EXPORT)
}

hook_pre_alias_add :: proc(name: string, value: string) {
	execute_hook_ctx(.PRE_ALIAS_ADD, HookContext{name = name, value = value})
}

hook_post_alias_add :: proc(name: string, value: string) {
	execute_hook_ctx(.POST_ALIAS_ADD, HookContext{name = name, value = value})
}

hook_pre_alias_remove :: proc(name: string, value: string) {
	execute_hook_ctx(.PRE_ALIAS_REMOVE, HookContext{name = name, value = value})
}

hook_post_alias_remove :: proc(name: string, value: string) {
	execute_hook_ctx(.POST_ALIAS_REMOVE, HookContext{name = name, value = value})
}

hook_pre_constant_add :: proc(name: string, value: string) {
	execute_hook_ctx(.PRE_CONSTANT_ADD, HookContext{name = name, value = value})
}

hook_post_constant_add :: proc(name: string, value: string) {
	execute_hook_ctx(.POST_CONSTANT_ADD, HookContext{name = name, value = value})
}

hook_pre_constant_remove :: proc(name: string, value: string) {
	execute_hook_ctx(.PRE_CONSTANT_REMOVE, HookContext{name = name, value = value})
}

hook_post_constant_remove :: proc(name: string, value: string) {
	execute_hook_ctx(.POST_CONSTANT_REMOVE, HookContext{name = name, value = value})
}

hook_pre_plugin_install :: proc(name: string) {
	execute_hook(.PRE_PLUGIN_INSTALL, name)
}

hook_post_plugin_install :: proc(name: string) {
	execute_hook(.POST_PLUGIN_INSTALL, name)
}
