// config_entry.odin - Generic config file management system
//
// This module provides a unified abstraction for managing configuration entries
// across different types (PATH, aliases, constants). It eliminates code duplication
// by providing generic implementations that work with any config entry type via
// the ConfigEntrySpec strategy pattern.

package wayu
import "core:fmt"
import "core:strings"
// ConfigEntryType defines the type of configuration entry
ConfigEntryType :: enum {
	PATH, // PATH entries (add_to_path "...")
	ALIAS, // Aliases (alias name="...")
	CONSTANT, // Environment variables (export NAME="...")
}

// ConfigEntry represents a single configuration entry
ConfigEntry :: struct {
	type:  ConfigEntryType,
	name:  string, // PATH entry, alias name, or constant name
	value: string, // Empty for PATH, command for alias, value for constant
	line:  string, // Original line from config file
}

// ConfigEntrySpec defines how to work with a specific entry type (Strategy Pattern)
ConfigEntrySpec :: struct {
	type:               ConfigEntryType,
	cli_name:           string, // command word in help/usage text: "path", "alias", "const"
	display_name:       string, // e.g., "PATH", "Alias", "Constant"
	icon:               string, // e.g., "📂", "🔑", "💾"

	// Optional special actions
	has_clean:          bool, // PATH has clean action
	has_dedup:          bool, // PATH has dedup action
	fields_count:       int, // 1 for path, 2 for alias/constants

	// Form configuration
	field_labels:       []string, // Argument names for usage errors
	field_placeholders: []string, // Field placeholders

	// --------------------------------------------------------------------
	// TOML-first operations (code review D3, 2026-04-24).
	//
	// Non-nil on specs that use the generic `handle_toml_entry_command`
	// dispatcher. Currently wired for ALIAS + CONSTANTS; PATH keeps its own
	// handler because it needs CLEAN/DEDUP, filesystem-aware validation,
	// and post-mutation reload messaging.
	// --------------------------------------------------------------------
	toml_add:           proc(entry: ConfigEntry) -> (ok: bool, err: string),
	toml_remove:        proc(name: string) -> (ok: bool, err: string),
	toml_list:          proc(),
	toml_get:           proc(name: string),

	// Optional hooks executed around each mutation. Nil-safe.
	// `value` is the alias command / constant value ("" on remove).
	hook_pre_add:       proc(name: string, value: string),
	hook_post_add:      proc(name: string, value: string),
	hook_pre_remove:    proc(name: string, value: string),
	hook_post_remove:   proc(name: string, value: string),

	// Optional callback run after toml_list (used by ALIAS to print external
	// alias sources below the native list).
	list_epilogue:      proc(),
}

// Generic dispatcher for the entry-store commands. Used by
// `handle_alias_command` and `handle_constants_command`. Assumes the spec has
// all four `toml_*` fields set; falls back to `handle_config_command` for
// actions outside ADD/REMOVE/LIST/GET (e.g. HELP, UNKNOWN).
handle_toml_entry_command :: proc(spec: ^ConfigEntrySpec, action: Action, args: []string) {
	if !ensure_wayu_toml_exists() {
		print_error_simple("Failed to create wayu.toml")
		wayu_exit(EXIT_IOERR)
	}

	if spec.toml_add != nil {
		#partial switch action {
		case .ADD:
			if len(args) == 0 {
				print_cli_usage_error(spec, "add")
				wayu_exit(EXIT_USAGE)
			}
			entry := parse_args_to_entry(spec, args)
			defer cleanup_entry(&entry)
			if !is_entry_complete(entry) {
				print_cli_usage_error(spec, "add")
				wayu_exit(EXIT_USAGE)
			}
			if spec.hook_pre_add != nil && entry_add_is_valid(spec, entry) do spec.hook_pre_add(entry.name, entry.value)
			ok, err := spec.toml_add(entry)
			if !ok {
				exit_with_entry_error(err)
			}
			if spec.hook_post_add != nil do spec.hook_post_add(entry.name, entry.value)
			return
		case .REMOVE:
			if len(args) == 0 {
				print_cli_usage_error(spec, "remove")
				wayu_exit(EXIT_USAGE)
			}
			if spec.hook_pre_remove != nil && entry_exists_in_store(spec, args[0]) do spec.hook_pre_remove(args[0], "")
			ok, err := spec.toml_remove(args[0])
			if !ok {
				exit_with_entry_error(err)
			}
			if spec.hook_post_remove != nil do spec.hook_post_remove(args[0], "")
			return
		case .LIST:
			spec.toml_list()
			if spec.list_epilogue != nil do spec.list_epilogue()
			return
		case .GET:
			if len(args) == 0 {
				print_cli_usage_error(spec, "get")
				wayu_exit(EXIT_USAGE)
			}
			spec.toml_get(args[0])
			return
		}
	}

	// HELP, UNKNOWN and unsupported actions (CLEAN/DEDUP).
	handle_config_command(spec, action, args)

	if action == .LIST && spec.list_epilogue != nil {
		spec.list_epilogue()
	}
}

// Silent preview of spec.toml_add's validation, so pre_*_add hooks fire only
// for adds that pass it (OKAMI-230). The writer validates again and reports.
entry_add_is_valid :: proc(spec: ^ConfigEntrySpec, entry: ConfigEntry) -> bool {
	v: ValidationResult
	#partial switch spec.type {
	case .ALIAS:
		v = validate_alias(entry.name, entry.value)
	case .CONSTANT:
		v = validate_constant(entry.name, entry.value)
	case:
		return true
	}
	if len(v.error_message) > 0 do delete(v.error_message)
	if len(v.warning) > 0 do delete(v.warning)
	return v.valid
}

// True when `name` is an alias / constant of the store, so pre_*_remove
// hooks skip names that are not there. An unreadable store counts as
// present: the writer reports that error itself.
entry_exists_in_store :: proc(spec: ^ConfigEntrySpec, name: string) -> bool {
	kind: EntryKind
	#partial switch spec.type {
	case .ALIAS:
		kind = .ALIAS
	case .CONSTANT:
		kind = .ENV
	case:
		return true
	}
	store, _, ok := entries_read()
	if !ok {
		return true
	}
	defer entries_store_destroy(&store)
	return entries_find(&store, kind, name) >= 0
}

// Print an add/remove failure and exit with the code matching its kind:
// "I/O error..." is EXIT_IOERR, ENTRY_ERROR_CONFIG_PREFIX (malformed
// entries.json, reason already printed) is EXIT_CONFIG, everything else (not
// found, invalid input) is EXIT_DATAERR. The message is user-derived, so it
// is always printed through "%s" and never used as a format string. Frees
// `err`.
exit_with_entry_error :: proc(err: string) -> ! {
	exit_code := EXIT_DATAERR
	switch {
	case strings.has_prefix(err, "I/O error"):
		exit_code = EXIT_IOERR
		print_error_simple("%s", err)
	case strings.has_prefix(err, ENTRY_ERROR_CONFIG_PREFIX):
		exit_code = EXIT_CONFIG
	case:
		print_error_simple("%s", err)
	}
	delete(err)
	wayu_exit(exit_code)
}

// Print usage error with hint to TUI mode (CLI-specific error handling)
print_cli_usage_error :: proc(spec: ^ConfigEntrySpec, action: string) {
	print_error("Missing required arguments for '%s %s'", spec.cli_name, action)
	fmt.println()

	// Show usage based on action
	switch action {
	case "add":
		if spec.fields_count == 1 {
			fmt.printfln("Usage: wayu %s add <%s>", spec.cli_name, spec.field_labels[0])
			fmt.println()
			fmt.printfln("Example:")
			fmt.printfln("  wayu %s add %s", spec.cli_name, spec.field_placeholders[0])
		} else {
			fmt.printfln(
				"Usage: wayu %s add <%s> <%s>",
				spec.cli_name,
				spec.field_labels[0],
				spec.field_labels[1],
			)
			fmt.println()
			fmt.printfln("Example:")
			fmt.printfln(
				"  wayu %s add %s %s",
				spec.cli_name,
				spec.field_placeholders[0],
				spec.field_placeholders[1],
			)
		}
	case "remove":
		fmt.printfln("Usage: wayu %s rm <%s>", spec.cli_name, spec.field_labels[0])
		fmt.println()
		fmt.printfln("Example:")
		fmt.printfln("  wayu %s rm %s", spec.cli_name, spec.field_placeholders[0])
	case "get":
		fmt.printfln("Usage: wayu %s get <%s>", spec.cli_name, spec.field_labels[0])
		fmt.println()
		fmt.printfln("Example:")
		fmt.printfln("  wayu %s get %s", spec.cli_name, spec.field_placeholders[0])
	}

	fmt.println()
	fmt.printfln(
		"%sHint:%s For interactive mode, use: %swayu --tui%s",
		get_muted(),
		RESET,
		get_primary(),
		RESET,
	)
}

// Actions the path/alias/const handlers leave to the shared code: HELP,
// UNKNOWN, and CLEAN/DEDUP on a spec that has no such action.
handle_config_command :: proc(spec: ^ConfigEntrySpec, action: Action, args: []string) {
	#partial switch action {
	case .CLEAN:
		if !spec.has_clean {
			print_error("%s command does not support clean action", spec.display_name)
			wayu_exit(EXIT_GENERAL)
		}
	// Command-specific clean implementation
	// This will be called from command files (e.g., clean_missing_paths)
	case .DEDUP:
		if !spec.has_dedup {
			print_error("%s command does not support dedup action", spec.display_name)
			wayu_exit(EXIT_GENERAL)
		}
	// Command-specific dedup implementation
	// This will be called from command files (e.g., remove_duplicate_paths)
	case .HELP:
		print_config_help(spec)
	case .UNKNOWN:
		fmt.eprintfln("Unknown %s action", spec.display_name)
		print_config_help(spec)
		wayu_exit(EXIT_USAGE)
	}
}

// Helper: Read all entries of `spec`'s type from the entry store (exits
// EXIT_CONFIG when entries.json is malformed). Free with cleanup_entries.
read_config_entries :: proc(spec: ^ConfigEntrySpec) -> []ConfigEntry {
	switch spec.type {
	case .PATH:
		return read_path_config_entries()
	case .ALIAS:
		return read_alias_entries()
	case .CONSTANT:
		return read_env_entries()
	}
	return {}
}

// Helper: Parse command line args to entry
parse_args_to_entry :: proc(spec: ^ConfigEntrySpec, args: []string) -> ConfigEntry {
	entry := ConfigEntry {
		type = spec.type,
	}

	switch spec.fields_count {
	case 1:
		if len(args) >= 1 {
			entry.name = strings.clone(args[0])
		}
		entry.value = ""
	case 2:
		if len(args) >= 2 {
			entry.name = strings.clone(args[0])
			// Join remaining args as value (for commands with spaces)
			entry.value = strings.join(args[1:], " ")
		}
	}

	return entry
}

// Helper: Check if entry is complete
is_entry_complete :: proc(entry: ConfigEntry) -> bool {
	if len(entry.name) == 0 {
		return false
	}
	// PATH only needs name, others need value too
	if entry.type != .PATH && len(entry.value) == 0 {
		return false
	}
	return true
}

// Helper: Cleanup single entry
// Note: String fields are intentionally not deleted here because
// they may come from different allocation contexts (temp allocator,
// string literals, etc.). The backing slice/array is freed by the caller.
// Free every non-empty field of a ConfigEntry and then reset them.
//
// Contract: callers must either heap-allocate (strings.clone / fmt.aprintf)
// all string fields before passing the entry here, or set them to the empty
// string so the delete() is a no-op. Callers that intentionally hold string
// literals (tests with inline data, static fixtures) must use plain
// `delete(entries)` on the slice instead of `cleanup_entries`.
//
// Before this became a full free it was a no-op — which silently leaked
// every parsed entry (parse_path_line / parse_alias_line / parse_constant_line
// all strings.clone their outputs). 30+ leaks reported by the tracking
// allocator traced back to this single function.
cleanup_entry :: proc(entry: ^ConfigEntry) {
	if len(entry.name) > 0 {
		delete(entry.name)
	}
	if len(entry.value) > 0 {
		delete(entry.value)
	}
	if len(entry.line) > 0 {
		delete(entry.line)
	}
	entry.name = ""
	entry.value = ""
	entry.line = ""
}

// Helper: Cleanup entry array
cleanup_entries :: proc(entries: ^[]ConfigEntry) {
	for &entry in entries {
		cleanup_entry(&entry)
	}
	delete(entries^)
}

// Generic help printer
print_config_help :: proc(spec: ^ConfigEntrySpec) {
	// Title
	plural := spec.display_name
	if strings.has_suffix(plural, "s") {
		plural = fmt.aprintf("%ses", plural)
	} else {
		plural = fmt.aprintf("%ss", plural)
	}
	defer delete(plural)
	title := fmt.aprintf(
		"\n%s%swayu %s - Manage %s%s\n\n",
		BOLD,
		get_primary(),
		spec.cli_name,
		plural,
		RESET,
	)
	defer delete(title)
	fmt.print(title)

	// Usage section
	fmt.printf("%s%sUSAGE:%s\n", BOLD, get_secondary(), RESET)

	// Every line is a complete command: the CLI never prompts, so an action
	// without its arguments is a usage error (exit 64).
	label := strings.to_lower(spec.display_name, context.temp_allocator)
	if spec.fields_count == 1 {
		fmt.printfln("  wayu %s add [<name>=]<%s>", spec.cli_name, label)
	} else {
		fmt.printfln("  wayu %s add <%s> <value>", spec.cli_name, label)
	}

	fmt.printfln("  wayu %s rm <%s>", spec.cli_name, label)
	fmt.printfln("  wayu %s get <%s>", spec.cli_name, label)
	fmt.printfln("  wayu %s list", spec.cli_name)
	if spec.type == .CONSTANT {
		fmt.printfln(
			"  wayu %s list --reveal    %s# show secret-looking values unmasked%s",
			spec.cli_name,
			get_muted(),
			RESET,
		)
	}

	if spec.has_clean {
		fmt.printfln("  wayu %s clean", spec.cli_name)
	}
	if spec.has_dedup {
		fmt.printfln("  wayu %s dedup", spec.cli_name)
	}

	fmt.printfln("  wayu %s help", spec.cli_name)

	// Examples section - specific to each type
	fmt.println()
	fmt.printf("%s%sEXAMPLES:%s\n", BOLD, get_secondary(), RESET)

	switch spec.type {
	case .PATH:
		// PATH-specific examples
		fmt.printfln("  %s# Add a directory to PATH%s", get_muted(), RESET)
		fmt.printfln("  wayu path add /usr/local/bin")
		fmt.printfln("  wayu path add $HOME/go/bin")
		fmt.println()
		fmt.printfln("  %s# List all PATH entries%s", get_muted(), RESET)
		fmt.printfln("  wayu path list")
		fmt.println()
		fmt.printfln("  %s# Remove a PATH entry%s", get_muted(), RESET)
		fmt.printfln("  wayu path rm /usr/local/bin")
		fmt.println()
		fmt.printfln("  %s# Clean non-existent directories%s", get_muted(), RESET)
		fmt.printfln("  wayu path clean --yes")
		fmt.println()
		fmt.printfln("  %s# Remove duplicates%s", get_muted(), RESET)
		fmt.printfln("  wayu path dedup --yes")

	case .ALIAS:
		// ALIAS-specific examples
		fmt.printfln("  %s# Create a simple alias%s", get_muted(), RESET)
		fmt.printfln("  wayu alias add ll 'ls -lah'")
		fmt.printfln("  wayu alias add gcm 'git commit -m'")
		fmt.println()
		fmt.printfln("  %s# Create an alias with arguments%s", get_muted(), RESET)
		fmt.printfln("  wayu alias add gp 'git push'")
		fmt.printfln("  wayu alias add gs 'git status'")
		fmt.println()
		fmt.printfln("  %s# List all aliases%s", get_muted(), RESET)
		fmt.printfln("  wayu alias list")
		fmt.println()
		fmt.printfln("  %s# Remove an alias%s", get_muted(), RESET)
		fmt.printfln("  wayu alias rm ll")
		fmt.println()
		fmt.printfln("  %s# Print an alias's command (exact name)%s", get_muted(), RESET)
		fmt.printfln("  wayu alias get gs")

	case .CONSTANT:
		// CONSTANT-specific examples
		fmt.printfln("  %s# Add an environment variable%s", get_muted(), RESET)
		fmt.printfln("  wayu const add API_KEY 'sk-abc123'")
		fmt.printfln("  wayu const add EDITOR vim")
		fmt.println()
		fmt.printfln("  %s# Add a variable with spaces (use quotes)%s", get_muted(), RESET)
		fmt.printfln("  wayu const add GREETING 'Hello World'")
		fmt.println()
		fmt.printfln(
			"  %s# List all constants (secret-looking values shown as ********)%s",
			get_muted(),
			RESET,
		)
		fmt.printfln("  wayu const list")
		fmt.printfln("  wayu const list --full --reveal")
		fmt.println()
		fmt.printfln("  %s# Get a variable value%s", get_muted(), RESET)
		fmt.printfln("  wayu const get API_KEY")
		fmt.printfln("  wayu const get FIREWORKS_AI_API_KEY")
		fmt.println()
		fmt.printfln("  %s# Remove a constant%s", get_muted(), RESET)
		fmt.printfln("  wayu const rm API_KEY")
	}

	// Tips section
	fmt.println()
	fmt.printf("%s%sTIPS:%s\n", BOLD, get_secondary(), RESET)
	fmt.printfln(
		"  %s• get is exact; 'wayu search' matches partial names and acronyms%s",
		get_muted(),
		RESET,
	)
	fmt.printfln(
		"  %s• Add --yes to skip confirmation on destructive operations%s",
		get_muted(),
		RESET,
	)
	fmt.printfln("  %s• Use --tui for interactive mode%s", get_muted(), RESET)

	fmt.println()
}
EntryPath :: struct {
	path: string,
	name: string, // optional [paths] key (`name=path` form); "" derives one
}

EntryAlias :: struct {
	name:    string,
	command: string,
}

EntryConst :: struct {
	name:  string,
	value: string,
}

Entry :: union {
	EntryPath,
	EntryAlias,
	EntryConst,
}

// What entry_add / entry_remove did, so callers can tell a real change from
// an update, a no-op or a --dry-run preview.
EntryOutcome :: enum {
	FAILED, // nothing written; the error string says why
	ADDED, // new entry written
	UPDATED, // existing alias/constant replaced
	UNCHANGED, // PATH already present: nothing to do
	REMOVED, // entry removed
	DRY_RUN, // --dry-run: would change, nothing written
}

// Add an entry to the store. Both CLI and TUI use this for mutations from
// outside the spec-driven dispatchers.
//
// Mirrors the CLI: the same validation (PATH: path_add_check, i.e. the path
// must resolve and exist, like `wayu path add`), the same pre/post hooks
// (post only after a real change) and wayu.dry_run (nothing written, hooks
// skipped). Error strings are heap-owned (caller deletes when non-empty).
entry_add :: proc(entry: Entry) -> (EntryOutcome, string) {
	// Invalid hooks.conf: refuse before writing (the CLI exits 78 instead).
	if msg, bad := hook_config_error(); bad {
		return .FAILED, strings.clone(msg)
	}
	if msg, bad := entries_unreadable_error(); bad {
		return .FAILED, strings.clone(msg)
	}
	switch e in entry {
	case EntryPath:
		expanded, check_err, code := path_add_check(e.path)
		defer delete(expanded)
		if code != EXIT_SUCCESS {
			return .FAILED, check_err
		}
		if path_add_would_change(e.path, e.name) {
			hook_pre_path_add(expanded)
		}
		#partial switch path_add_result(e.path, e.name) {
		case .OK:
			if wayu.dry_run {
				return .DRY_RUN, ""
			}
			regenerate_init_core_silently()
			hook_post_path_add(expanded)
			return .ADDED, ""
		case .NOOP:
			return .UNCHANGED, ""
		case .IO_ERROR:
			return .FAILED, strings.clone("I/O error: failed to write the PATH entry")
		case:
			// The writer reported the reason (bad/taken name) via print_error.
			if msg := take_print_capture(); len(msg) > 0 {
				return .FAILED, msg
			}
			return .FAILED, strings.clone("failed to write the PATH entry")
		}
	case EntryAlias:
		return entry_add_with_hooks(
			&ALIAS_SPEC,
			ConfigEntry{type = .ALIAS, name = e.name, value = e.command},
		)
	case EntryConst:
		return entry_add_with_hooks(
			&CONSTANTS_SPEC,
			ConfigEntry{type = .CONSTANT, name = e.name, value = e.value},
		)
	}
	return .FAILED, strings.clone("unknown entry type")
}

@(private = "file")
entry_add_with_hooks :: proc(
	spec: ^ConfigEntrySpec,
	entry: ConfigEntry,
) -> (
	EntryOutcome,
	string,
) {
	existed := entry_exists_in_store(spec, entry.name)
	if spec.hook_pre_add != nil && entry_add_is_valid(spec, entry) do spec.hook_pre_add(entry.name, entry.value)
	ok, err := spec.toml_add(entry)
	if !ok {
		return .FAILED, err
	}
	if wayu.dry_run {
		return .DRY_RUN, err
	}
	if spec.hook_post_add != nil do spec.hook_post_add(entry.name, entry.value)
	return .UPDATED if existed else .ADDED, err
}

// Remove an entry by identity (dir or key for EntryPath, name for
// the others). The non-identity fields on the variant are ignored. Same hook
// / dry-run semantics as entry_add.
entry_remove :: proc(entry: Entry) -> (EntryOutcome, string) {
	// Invalid hooks.conf: refuse before writing (the CLI exits 78 instead).
	if msg, bad := hook_config_error(); bad {
		return .FAILED, strings.clone(msg)
	}
	if msg, bad := entries_unreadable_error(); bad {
		return .FAILED, strings.clone(msg)
	}
	switch e in entry {
	case EntryPath:
		// Hooks get the stored directory, also when the target is a key (as the CLI).
		hook_path, found := path_entry_lookup(e.path)
		defer delete(hook_path)
		if found {
			hook_pre_path_remove(hook_path)
		}
		#partial switch path_remove_result(e.path) {
		case .OK:
			if wayu.dry_run {
				return .DRY_RUN, ""
			}
			regenerate_init_core_silently()
			hook_post_path_remove(hook_path)
			return .REMOVED, ""
		case .IO_ERROR:
			return .FAILED, strings.clone("I/O error: failed to remove the PATH entry")
		case:
			if msg := take_print_capture(); len(msg) > 0 {
				return .FAILED, msg
			}
			return .FAILED, strings.clone("failed to remove the PATH entry")
		}
	case EntryAlias:
		return entry_remove_with_hooks(&ALIAS_SPEC, e.name)
	case EntryConst:
		return entry_remove_with_hooks(&CONSTANTS_SPEC, e.name)
	}
	return .FAILED, strings.clone("unknown entry type")
}

// Change the directory of the PATH entry `target` (key or path) to
// `raw_path` in place (TUI edit): same checks as entry_add (path_add_check),
// runs the remove hooks for the old directory and the add hooks for the new.
entry_replace_path :: proc(target, raw_path: string) -> (EntryOutcome, string) {
	if msg, bad := hook_config_error(); bad {
		return .FAILED, strings.clone(msg)
	}
	if msg, bad := entries_unreadable_error(); bad {
		return .FAILED, strings.clone(msg)
	}
	expanded, check_err, code := path_add_check(raw_path)
	defer delete(expanded)
	if code != EXIT_SUCCESS {
		return .FAILED, check_err
	}
	old_path, found := path_entry_lookup(target)
	defer delete(old_path)
	if found && old_path != expanded {
		hook_pre_path_remove(old_path)
		hook_pre_path_add(expanded)
	}
	#partial switch path_replace_result(target, raw_path) {
	case .OK:
		if wayu.dry_run {
			return .DRY_RUN, ""
		}
		regenerate_init_core_silently()
		hook_post_path_remove(old_path)
		hook_post_path_add(expanded)
		return .UPDATED, ""
	case .NOOP:
		return .UNCHANGED, ""
	case .IO_ERROR:
		return .FAILED, strings.clone("I/O error: failed to write the PATH entry")
	case:
		if msg := take_print_capture(); len(msg) > 0 {
			return .FAILED, msg
		}
		return .FAILED, strings.clone("failed to update the PATH entry")
	}
}

@(private = "file")
entry_remove_with_hooks :: proc(spec: ^ConfigEntrySpec, name: string) -> (EntryOutcome, string) {
	if spec.hook_pre_remove != nil && entry_exists_in_store(spec, name) do spec.hook_pre_remove(name, "")
	ok, err := spec.toml_remove(name)
	if !ok {
		return .FAILED, err
	}
	if wayu.dry_run {
		return .DRY_RUN, err
	}
	if spec.hook_post_remove != nil do spec.hook_post_remove(name, "")
	return .REMOVED, err
}
// Basenames that almost never carry meaning on their own. When we see one,
// we prefix with the parent directory to keep keys self-describing.
COMMON_PATH_BASENAMES :: []string {
	"bin",
	"sbin",
	"lib",
	"lib64",
	"share",
	"etc",
	"var",
	"src",
	"dist",
	"build",
	"target",
	"out",
	"node_modules",
	"vendor",
	"current",
	"default",
	"latest",
}

// Lowercase + replace anything outside [a-z0-9_] with `_`. Returns "" when
// the input has no usable characters so callers can fall back.
//
// Special case: a leading dot is rendered as a literal `hidden_` prefix so
// dotfile dirs round-trip to a self-describing key:
//   `.local`  → `hidden_local`
//   `.cargo`  → `hidden_cargo`
//   `.config` → `hidden_config`
sanitize_path_key :: proc(s: string) -> string {
	if len(s) == 0 {
		return ""
	}

	hidden := s[0] == '.'

	// Worst case: every char becomes `_` plus the optional `hidden_` prefix.
	buf := make([]byte, len(s) + 7)
	defer delete(buf)
	n := 0
	prefix_len := 0
	if hidden {
		copy(buf[:7], "hidden_")
		n = 7
		prefix_len = 7
	}

	for i := 0; i < len(s); i += 1 {
		c := s[i]
		switch {
		case c >= 'A' && c <= 'Z':
			buf[n] = c + ('a' - 'A')
			n += 1
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9', c == '_':
			buf[n] = c
			n += 1
		case:
			// Skip the leading dot (already encoded as `hidden_`) and any
			// leading garbage. Collapse internal runs to a single `_`.
			if n > prefix_len && buf[n - 1] != '_' {
				buf[n] = '_'
				n += 1
			}
		}
	}
	// Trim trailing `_`.
	for n > 0 && buf[n - 1] == '_' {n -= 1}
	// `""` if nothing remains — including bare-prefix cases like "." → "hidden"
	// would be misleading, so we treat them as empty and let the caller fall back.
	if n == 0 || n == prefix_len - 1  /* trimmed prefix tail `_` */{
		return ""
	}
	return strings.clone(string(buf[:n]))
}

is_common_path_basename :: proc(s: string) -> bool {
	for c in COMMON_PATH_BASENAMES {
		if s == c {
			return true
		}
	}
	return false
}

// Split a cleaned path into (parent_dir_basename, basename). Either may be
// empty (e.g. when the path is "/" or just "foo"). Caller does not own the
// returned strings — they're slices into `path`.
split_path_tail :: proc(path: string) -> (parent: string, base: string) {
	cleaned := strings.trim_right(path, "/")
	if len(cleaned) == 0 {
		return "", path
	}
	last := strings.last_index_byte(cleaned, '/')
	if last < 0 {
		return "", cleaned
	}
	base = cleaned[last + 1:]
	rest := cleaned[:last]
	prev := strings.last_index_byte(rest, '/')
	if prev < 0 {
		parent = rest
	} else {
		parent = rest[prev + 1:]
	}
	return
}

// Pick a unique TOML key for `path` given the set of `taken` keys.
//   /Users/me/dev/oss/Odin    → "odin"
//   /usr/local/bin            → "local_bin"   (bin is common)
//   /opt/homebrew/bin         → "homebrew_bin"
//   /Users/me/.cargo/bin      → "cargo_bin"
//   collisions                → "<base>_2", "<base>_3", ...
//
// Caller owns the returned string.
derive_path_key :: proc(path: string, taken: map[string]bool) -> string {
	parent, base := split_path_tail(path)

	// `base_key` is always heap-owned; fallback to a cloned literal when the
	// basename is unparseable (e.g. "." or pure punctuation) so we can free
	// it uniformly below.
	base_key := sanitize_path_key(base)
	if len(base_key) == 0 {
		base_key = strings.clone("path")
	}
	defer delete(base_key)

	key: string
	if is_common_path_basename(base_key) {
		parent_key := sanitize_path_key(parent)
		if len(parent_key) > 0 {
			key = fmt.aprintf("%s_%s", parent_key, base_key)
			delete(parent_key)
		} else {
			key = strings.clone(base_key)
		}
	} else {
		key = strings.clone(base_key)
	}

	if !(key in taken) {
		return key
	}

	// Collision — append "_2", "_3", ...
	stem := key
	defer delete(stem)
	for i := 2;; i += 1 {
		candidate := fmt.aprintf("%s_%d", stem, i)
		if !(candidate in taken) {
			return candidate
		}
		delete(candidate)
	}
}

// Parse a CLI path argument that may be either:
//   "/usr/local/bin"           → (name="", path="/usr/local/bin", explicit=false)
//   "local_bin=/usr/local/bin" → (name="local_bin", path="/usr/local/bin", explicit=true)
//
// The `name=path` form is recognised only when the LHS is a non-empty
// identifier (alphanum + underscore, no slash). Anything else is treated
// as a bare path so users can still add paths with `=` in them.
//
// Returned strings are slices of `arg` — caller does not own them.
parse_path_arg :: proc(arg: string) -> (name, path: string, explicit: bool) {
	eq := strings.index_byte(arg, '=')
	if eq <= 0 {
		return "", arg, false
	}

	lhs := arg[:eq]
	rhs := arg[eq + 1:]
	if len(rhs) == 0 {
		return "", arg, false
	}

	for i := 0; i < len(lhs); i += 1 {
		c := lhs[i]
		ok :=
			(c >= 'a' && c <= 'z') ||
			(c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') ||
			c == '_' ||
			c == '-'
		if !ok {
			return "", arg, false
		}
	}
	return lhs, rhs, true
}

// Reason (temp allocator) not to edit the entries now: entries.json can't be
// read or is malformed (the TUI shows it instead of exiting). The writers
// would otherwise fail deep inside.
entries_unreadable_error :: proc() -> (msg: string, bad: bool) {
	store, err, ok := entries_read()
	if !ok {
		return err, true
	}
	entries_store_destroy(&store)
	return "", false
}
