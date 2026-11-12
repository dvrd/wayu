// wayu_completions.odin - Auto-generate completions for wayu itself
//
// This module generates zsh, bash and fish completion scripts for wayu,
// enabling tab-completion for the CLI.

package wayu

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// One row per top-level command: the single source for command dispatch
// (cli_parser: name → Command, action word → Action), the per-command flag
// allow-list (command_accepts_flag), --json support, the COMMANDS / FLAGS
// sections of `wayu help`, and wayu's own zsh/bash/fish completions
// (OKAMI-234, OKAMI-282). `names[0]` is the canonical name; the rest are
// parser aliases. tests/unit/test_completions.odin checks every dispatchable
// Command has a row, every name and action word parses as the row says, and
// every offered word appears in all three completion scripts.
WayuCommandSpec :: struct {
	command:          Command,
	names:            []string,
	desc:             string,
	// Action words (the word after the command). Empty: the command takes
	// no action word and every later word is an argument. `-h`/`--help`
	// always mean .HELP.
	actions:          []WayuActionSpec,
	// Action when no action word is given.
	default_action:   Action,
	// Flags the command's handler parses itself, beyond the global flags.
	flags:            []WayuFlagSpec,
	// Actions whose output honors --json (OKAMI-239); --json anywhere else
	// is a usage error.
	json:             bit_set[Action],
	// Accept any dash token (version/help never write).
	any_flag:         bool,
	// Existing entries completions offer as the first argument of the
	// `arg_name_actions` actions (`alias rm <TAB>` → alias names), listed at
	// TAB time by the hidden `wayu completions names <kind>` (OKAMI-181/182).
	arg_names:        CompletionNames,
	arg_name_actions: bit_set[Action],
}

// Kinds of existing entries `wayu completions names <kind>` prints.
CompletionNames :: enum {
	NONE,
	PATH,
	ALIAS,
	CONSTANT,
	PLUGIN,
	FUNCTION,
	COMPLETION,
	SCRIPT,
	SECRET,
	BACKUP,
	BACKUP_INDEX,
}

// The <kind> word of `wayu completions names <kind>`.
COMPLETION_NAMES_KIND := [CompletionNames]string {
	.NONE         = "",
	.PATH         = "path",
	.ALIAS        = "alias",
	.CONSTANT     = "const",
	.PLUGIN       = "plugin",
	.FUNCTION     = "function",
	.COMPLETION   = "completion",
	.SCRIPT       = "script",
	.SECRET       = "secret",
	.BACKUP       = "backup",
	.BACKUP_INDEX = "backup-index",
}

// An action word. `desc == ""` marks a parser-only synonym (`config e`)
// that help and completions don't offer.
WayuActionSpec :: struct {
	word:   string,
	action: Action,
	desc:   string,
}

// A command-specific flag. A `flag` ending in '=' matches as a prefix
// (`--category=dev`). `desc == ""` hides it from help and completions.
// Flags that take a value: WAYU_FLAG_VALUES.
WayuFlagSpec :: struct {
	flag: string,
	desc: string,
}

WAYU_COMMAND_SPECS := [?]WayuCommandSpec {
	{
		command = .PATH,
		names = {"path"},
		desc = "Manage PATH entries",
		default_action = .LIST,
		json = {.LIST},
		arg_names = .PATH,
		arg_name_actions = {.REMOVE, .GET},
		actions = {
			{"add", .ADD, "Add a PATH entry"},
			{"remove", .REMOVE, "Remove a PATH entry"},
			{"rm", .REMOVE, "Remove a PATH entry"},
			{"list", .LIST, "List PATH entries"},
			{"ls", .LIST, "List PATH entries"},
			{"get", .GET, "Get a PATH entry"},
			{"clean", .CLEAN, "Remove missing directories"},
			{"dedup", .DEDUP, "Remove duplicates"},
			{"help", .HELP, "Show help"},
		},
	},
	{
		command = .ALIAS,
		names = {"alias"},
		desc = "Manage shell aliases",
		default_action = .LIST,
		json = {.LIST},
		arg_names = .ALIAS,
		arg_name_actions = {.REMOVE, .GET},
		actions = {
			{"add", .ADD, "Add an alias"},
			{"remove", .REMOVE, "Remove an alias"},
			{"rm", .REMOVE, "Remove an alias"},
			{"list", .LIST, "List aliases"},
			{"ls", .LIST, "List aliases"},
			{"get", .GET, "Get alias value"},
			{"help", .HELP, "Show help"},
		},
	},
	{
		command = .CONSTANTS,
		names = {"constants", "const", "env"},
		desc = "Manage environment constants",
		default_action = .LIST,
		json = {.LIST},
		arg_names = .CONSTANT,
		arg_name_actions = {.REMOVE, .GET},
		actions = {
			{"add", .ADD, "Add a constant"},
			{"remove", .REMOVE, "Remove a constant"},
			{"rm", .REMOVE, "Remove a constant"},
			{"list", .LIST, "List constants"},
			{"ls", .LIST, "List constants"},
			{"get", .GET, "Get constant value"},
			{"help", .HELP, "Show help"},
		},
		flags = {
			{"--reveal", "Show secret values unmasked in list"},
			{"--secret", "Store the value encrypted (const add)"},
			{"--run-only", "Encrypted, only for 'wayu secrets run' (const add)"},
		},
	},
	{
		command = .SECRETS,
		names = {"secrets", "secret"},
		desc = "Encrypted secret constants",
		default_action = .LIST,
		actions = {
			{"list", .LIST, "List secret names"},
			{"ls", .LIST, "List secret names"},
			{"rekey", .UPDATE, "New master key, re-encrypt every secret"},
			{"lock", .CLEAN, "Delete the decrypted session cache"},
			{"run", .RUN, "Run a command with secrets set"},
			{"identity", .IDENTITY, "Print this machine's age recipient (experimental)"},
			{
				"recipient",
				.RECIPIENT,
				"Machines that read the secrets: list, add, rm, rename (experimental)",
			},
			{"adopt", .ADOPT, "Accept the data key in this machine's stanza (experimental)"},
			{"recovery", .RECOVERY, "Recovery passphrase: add, rm, unlock (experimental)"},
			{"cache", .TURBO, ""},
			{"help", .HELP, "Show help"},
		},
		json = {.RECIPIENT},
		flags = {
			{"--name", "Recipient name (identity, recipient add; default: hostname -s)"},
			{"--name=", ""},
		},
	},
	{
		command = .SEARCH,
		names = {"search", "find", "f"},
		desc = "Fuzzy search across all configs",
		default_action = .LIST,
		json = {.LIST},
	},
	{
		command = .COMPLETIONS,
		names = {"completions"},
		desc = "Manage shell completion scripts",
		default_action = .LIST,
		arg_names = .COMPLETION,
		arg_name_actions = {.REMOVE},
		actions = {
			{"add", .ADD, "Add a completion script"},
			{"remove", .REMOVE, "Remove a completion"},
			{"rm", .REMOVE, "Remove a completion"},
			{"list", .LIST, "List completions"},
			{"ls", .LIST, "List completions"},
			{"generate", .UPDATE, "Generate wayu's own completions"},
			{"gen", .UPDATE, ""},
			{"bash", .CHECK, "Print bash completion for wayu"},
			{"fish", .GET, "Print fish completion for wayu"},
			{"zsh", .TURBO, "Print zsh completion for wayu"},
			{"names", .SEARCH, ""},
			{"fpath", .FPATH, "Managed zsh completion dirs (list, add, rm)"},
			{"help", .HELP, "Show help"},
		},
	},
	{
		command = .BACKUP,
		names = {"backup"},
		desc = "Manage configuration backups",
		default_action = .LIST,
		json = {.LIST},
		actions = {
			{"list", .LIST, "List backups"},
			{"ls", .LIST, "List backups"},
			{"restore", .RESTORE, "Restore from backup"},
			{"remove", .REMOVE, "Clean up old backups"},
			{"rm", .REMOVE, "Clean up old backups"},
			{"help", .HELP, "Show help"},
		},
	},
	{
		command = .PLUGIN,
		names = {"plugin"},
		desc = "Manage shell plugins",
		default_action = .LIST,
		json = {.LIST},
		arg_names = .PLUGIN,
		arg_name_actions = {.REMOVE, .GET, .ENABLE, .DISABLE, .PRIORITY, .UPDATE},
		actions = {
			{"add", .ADD, "Install a plugin"},
			{"remove", .REMOVE, "Remove a plugin"},
			{"rm", .REMOVE, "Remove a plugin"},
			{"list", .LIST, "List installed plugins"},
			{"ls", .LIST, "List installed plugins"},
			{"get", .GET, "Show plugin info"},
			{"search", .SEARCH, "Browse popular plugins"},
			{"enable", .ENABLE, "Enable a plugin"},
			{"disable", .DISABLE, "Disable a plugin"},
			{"priority", .PRIORITY, "Set plugin load priority"},
			{"check", .CHECK, "Check for updates"},
			{"update", .UPDATE, "Update plugins"},
			{"help", .HELP, "Show help"},
		},
		flags = {
			{"--all", "Update all plugins"},
			{"-a", ""},
			{"--category", "Filter 'plugin search' by category"},
			{"-c", ""},
			{"--category=", ""},
			{"--use", "Glob of files to load (plugin add)"},
			{"--use=", ""},
		},
	},
	{
		command = .INIT,
		names = {"init"},
		desc = "Initialize wayu configuration",
		flags = {{"--template", "Apply a template after init"}, {"--template=", ""}},
	},
	{
		command = .CONFIG,
		names = {"config"},
		desc = "Manage configuration files",
		default_action = .HELP,
		actions = {
			{"edit", .UPDATE, "Edit wayu.toml in $EDITOR"},
			{"extend", .ADD, "Edit extra config in $EDITOR"},
			{"e", .ADD, ""},
			{"scan", .CHECK, "Detect shell config"},
			{"s", .CHECK, ""},
			{"detect", .CHECK, ""},
			{"help", .HELP, "Show help"},
		},
		flags = {{"--fix", "Repair what 'config scan' found"}},
	},
	{
		command = .BUILD,
		names = {"build"},
		desc = "Compile wayu.toml + entries.json into shell init files",
		default_action = .LIST,
		actions = {
			{"turbo", .TURBO, "Generate turbo file"},
			{"profile", .CHECK, "Profile startup"},
			{"clean", .CLEAN, "Clear the [tools] evalcache"},
			{"help", .HELP, "Show help"},
		},
	},
	{
		command = .EXPORT,
		names = {"export"},
		desc = "Generate turbo export file",
		default_action = .TURBO,
		actions = {
			{"turbo", .TURBO, "Generate turbo file"},
			{"--turbo", .TURBO, ""},
			{"eval", .EVAL, "Output for eval"},
			{"--eval", .EVAL, ""},
			{"check", .CHECK, "Check the turbo file is current"},
			{"--check", .CHECK, ""},
			{"list", .LIST, "Show formats"},
			{"ls", .LIST, "Show formats"},
			{"help", .HELP, "Show help"},
		},
		flags = {{"--turbo", ""}, {"--eval", ""}, {"--check", ""}},
	},
	{
		command = .TOML,
		names = {"toml"},
		desc = "TOML configuration management",
		default_action = .CHECK,
		actions = {
			{"validate", .CHECK, "Validate wayu.toml"},
			{"show", .GET, "Show config"},
			{"keys", .LIST, "List keys"},
			{"help", .HELP, "Show help"},
		},
	},
	{
		command        = .DOCTOR,
		names          = {"doctor"},
		desc           = "Health check and diagnostics",
		default_action = .LIST,
		json           = {.LIST},
		flags          = {
			{"--fix", "Repair what can be repaired"},
			{"--profile", "Profile shell startup"},
			{"--optimize", ""}, // removed: exits 64 with a pointer
		},
	},
	{
		command = .TEMPLATE,
		names = {"template"},
		desc = "Configuration presets",
		default_action = .LIST,
		actions = {
			{"list", .LIST, "List templates"},
			{"ls", .LIST, "List templates"},
			{"apply", .ADD, "Apply a template"},
			{"help", .HELP, "Show help"},
		},
	},
	{
		command = .HOOKS,
		names = {"hooks"},
		desc = "Pre/post action hooks",
		default_action = .LIST,
		actions = {
			{"list", .LIST, "List hooks"},
			{"ls", .LIST, "List hooks"},
			{"edit", .ADD, "Edit hooks"},
			{"help", .HELP, "Show help"},
		},
	},
	{
		command = .FUNCTION,
		names = {"function", "functions", "func", "fn"},
		desc = "Manage custom shell functions",
		default_action = .LIST,
		arg_names = .FUNCTION,
		arg_name_actions = {.ADD, .REMOVE},
		actions = {
			{"add", .ADD, "Create a function in $EDITOR"},
			{"edit", .ADD, "Edit a function"},
			{"new", .ADD, "Create a function"},
			{"list", .LIST, "List functions"},
			{"ls", .LIST, "List functions"},
			{"remove", .REMOVE, "Delete a function"},
			{"rm", .REMOVE, "Delete a function"},
			{"delete", .REMOVE, "Delete a function"},
			{"help", .HELP, "Show help"},
		},
	},
	{
		command = .SCRIPT,
		names = {"script", "scripts"},
		desc = "Manage standalone scripts on PATH (any language)",
		default_action = .LIST,
		json = {.LIST},
		arg_names = .SCRIPT,
		arg_name_actions = {.UPDATE, .REMOVE, .BUILD},
		actions = {
			{"new", .ADD, "Create a script in $EDITOR and build it"},
			{"edit", .UPDATE, "Edit and rebuild a script"},
			{"list", .LIST, "List scripts"},
			{"ls", .LIST, "List scripts"},
			{"remove", .REMOVE, "Delete a script"},
			{"rm", .REMOVE, "Delete a script"},
			{"import", .IMPORT, "Import existing script files"},
			{"build", .BUILD, "Build stale scripts"},
			{"help", .HELP, "Show help"},
		},
		flags = {
			{"--lang", "Language of 'script new'"},
			{"--lang=", ""},
			{"--copy", "'script import': keep the original files"},
			{"--allow-build", "'script import': run the build commands files declare"},
		},
	},
	{
		command = .OPTIMIZE,
		names = {"optimize"},
		desc = "Move installer lines from shell startup files into wayu",
		default_action = .UPDATE,
		flags = {{"--check", "Exit 1 when startup-file lines can be optimized"}, {"--notify", ""}},
	},
	{
		command = .RELOAD,
		names = {"reload", "watch", "hot-reload"},
		desc = "Watch config files and regenerate init files",
	},
	{command = .VERSION, names = {"version"}, desc = "Show version", any_flag = true},
	{command = .HELP, names = {"help"}, desc = "Show help", any_flag = true},
}

// Row for a command word (a name or alias), nil when there is none.
find_command_spec_by_name :: proc(name: string) -> ^WayuCommandSpec {
	for &spec in WAYU_COMMAND_SPECS {
		for n in spec.names {
			if n == name {
				return &spec
			}
		}
	}
	return nil
}

// Row for a Command, nil for .UNKNOWN.
find_command_spec :: proc(command: Command) -> ^WayuCommandSpec {
	for &spec in WAYU_COMMAND_SPECS {
		if spec.command == command {
			return &spec
		}
	}
	return nil
}

// Action for an action word of `spec` (`-h`/`--help` always .HELP);
// .UNKNOWN when the command has no such word.
find_spec_action :: proc(spec: ^WayuCommandSpec, word: string) -> Action {
	if word == "-h" || word == "--help" {
		return .HELP
	}
	for a in spec.actions {
		if a.word == word {
			return a.action
		}
	}
	return .UNKNOWN
}

// Flags a command's handler parses itself (beyond the global flags in
// cli_parser). `-h`/`--help` are accepted everywhere; version/help (and an
// unknown command, reported as such) accept anything.
command_accepts_flag :: proc(command: Command, arg: string) -> bool {
	if arg == "-h" || arg == "--help" {
		return true
	}
	spec := find_command_spec(command)
	if spec == nil {
		return true
	}
	if spec.any_flag {
		return true
	}
	for f in spec.flags {
		if f.flag == arg {
			return true
		}
		if strings.has_suffix(f.flag, "=") && strings.has_prefix(arg, f.flag) {
			return true
		}
	}
	return false
}

// Whether `--json` means something for this command/action. Help and
// unknown actions/commands report their own outcome, so they don't
// reject it.
command_supports_json :: proc(command: Command, action: Action) -> bool {
	if action == .HELP || action == .UNKNOWN {
		return true
	}
	spec := find_command_spec(command)
	if spec == nil || spec.any_flag {
		return true
	}
	return action in spec.json
}

// "path list, alias list, …": the commands that honor --json, for help.
json_commands_summary :: proc(allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for spec in WAYU_COMMAND_SPECS {
		if spec.json == {} {
			continue
		}
		if len(spec.actions) == 0 {
			if strings.builder_len(b) > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, spec.names[0])
			continue
		}
		for act in Action {
			if act not_in spec.json {
				continue
			}
			for a in spec.actions {
				if a.action != act || len(a.desc) == 0 {
					continue
				}
				if strings.builder_len(b) > 0 {
					strings.write_string(&b, ", ")
				}
				fmt.sbprintf(&b, "%s %s", spec.names[0], a.word)
				break
			}
		}
	}
	return strings.to_string(b)
}

// What a flag's value or a positional argument completes to (OKAMI-355).
WayuValue :: enum u8 {
	NONE, // no value (a flag) / nothing
	ANY, // takes a value; nothing to offer
	DIRS,
	FILES,
	COMMAND, // a command line (the words after `secrets run ... --`)
	NAMES, // existing entries: `wayu completions names <kind>`
	SHELLS,
	SOURCES,
	LANGS,
	CATEGORIES,
	TEMPLATES,
	PLUGIN_KEYS,
	FPATH_ACTIONS,
	RECIPIENT_ACTIONS,
	RECOVERY_ACTIONS,
}

// `position` of a WayuArgCompleter: every argument / the words after `--`.
ARG_EVERY :: 0
ARG_AFTER_DASHDASH :: -1

// Positional arguments completions offer values for, beyond the existing
// entries of a row's `arg_names` (first argument of `arg_name_actions`).
// `actions == {}`: a command without action words.
WayuArgCompleter :: struct {
	command:  Command,
	actions:  bit_set[Action],
	position: int, // 1-based argument after the action, ARG_EVERY or ARG_AFTER_DASHDASH
	value:    WayuValue,
	names:    CompletionNames, // value == .NAMES
}

WAYU_ARG_COMPLETERS := [?]WayuArgCompleter {
	{.PATH, {.ADD}, ARG_EVERY, .DIRS, .NONE},
	{.COMPLETIONS, {.ADD}, ARG_EVERY, .FILES, .NONE},
	{.COMPLETIONS, {.FPATH}, 1, .FPATH_ACTIONS, .NONE},
	{.COMPLETIONS, {.FPATH}, 2, .DIRS, .NONE},
	{.SECRETS, {.RUN}, ARG_AFTER_DASHDASH, .COMMAND, .NONE},
	{.SECRETS, {.RUN}, ARG_EVERY, .NAMES, .SECRET},
	{.SECRETS, {.RECIPIENT}, 1, .RECIPIENT_ACTIONS, .NONE},
	{.SECRETS, {.RECOVERY}, 1, .RECOVERY_ACTIONS, .NONE},
	{.BACKUP, {.LIST, .RESTORE, .REMOVE}, 1, .NAMES, .BACKUP},
	{.BACKUP, {.RESTORE}, 2, .NAMES, .BACKUP_INDEX},
	{.TEMPLATE, {.ADD}, 1, .TEMPLATES, .NONE},
	{.PLUGIN, {.ADD}, 1, .PLUGIN_KEYS, .NONE},
	{.SCRIPT, {.IMPORT}, ARG_EVERY, .FILES, .NONE},
}

// Command flags (WayuFlagSpec, without a trailing '=') that take the next
// word, or `--flag=word`, as their value, and what completions offer for it.
WayuFlagValue :: struct {
	command: Command,
	flag:    string,
	value:   WayuValue,
}

WAYU_FLAG_VALUES := [?]WayuFlagValue {
	{.PLUGIN, "--category", .CATEGORIES},
	{.PLUGIN, "-c", .CATEGORIES},
	{.PLUGIN, "--use", .ANY},
	{.INIT, "--template", .TEMPLATES},
	{.SCRIPT, "--lang", .LANGS},
	{.SECRETS, "--name", .ANY},
}

// Global flags (cli_parser) as completions offer them, anywhere on the line.
@(private = "file")
WayuGlobalFlag :: struct {
	flags:    []string,
	desc:     string,
	value:    WayuValue,
	top_only: bool, // only before the command word
}

@(private = "file")
WAYU_GLOBAL_FLAGS := [?]WayuGlobalFlag {
	{{"--help", "-h"}, "Show help", .NONE, false},
	{{"--version", "-v"}, "Show version", .NONE, true},
	{{"--dry-run", "-n"}, "Preview changes without writing", .NONE, false},
	{{"--yes", "-y"}, "Skip confirmation prompts", .NONE, false},
	{{"--no-color"}, "Disable colored output", .NONE, false},
	{{"--tui"}, "Launch interactive TUI mode", .NONE, true},
	{{"--shell"}, "Shell to act for", .SHELLS, false},
	{{"--source"}, "List views: which entries to show", .SOURCES, false},
	{{"--full", "-f"}, "List views: include external entries", .NONE, false},
}

// The fixed words a value completes to (nil for the dynamic kinds).
// Temp-allocated.
wayu_value_words :: proc(v: WayuValue) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	#partial switch v {
	case .SHELLS:
		append(&out, "zsh", "bash", "fish")
	case .SOURCES:
		append(&out, "wayu", "external", "inactive", "all")
	case .LANGS:
		for l in SCRIPT_LANGS {append(&out, l.name)}
	case .CATEGORIES:
		for p in POPULAR_PLUGINS {
			if !slice.contains(out[:], p.category) {
				append(&out, p.category)
			}
		}
	case .TEMPLATES:
		append(&out, ..TEMPLATE_NAMES[:])
	case .PLUGIN_KEYS:
		for p in POPULAR_PLUGINS {append(&out, p.key)}
	case .FPATH_ACTIONS:
		append(&out, "list", "add", "rm")
	case .RECIPIENT_ACTIONS:
		append(&out, "list", "add", "rm", "rename")
	case .RECOVERY_ACTIONS:
		append(&out, "add", "rm", "unlock")
	}
	return out[:]
}

// The completer a script runs, as one word its `_wayu_spec` reads:
// "w:<words>", "n:<kind>" (entries), "N:<kind>" (entries of the previous
// argument), "d" dirs, "f" files, "c" a command line, "-" nothing.
@(private = "file")
value_spec :: proc(v: WayuValue, names := CompletionNames.NONE) -> string {
	#partial switch v {
	case .NONE:
		return ""
	case .ANY:
		return "-"
	case .DIRS:
		return "d"
	case .FILES:
		return "f"
	case .COMMAND:
		return "c"
	case .NAMES:
		return fmt.tprintf(
			"%s:%s",
			"N" if names == .BACKUP_INDEX else "n",
			COMPLETION_NAMES_KIND[names],
		)
	}
	return fmt.tprintf("w:%s", strings.join(wayu_value_words(v), " ", context.temp_allocator))
}

// A word completions offer (action, flag, command) with its description.
@(private = "file")
CompletionWord :: struct {
	word: string,
	desc: string,
}

// One case branch of a generated lookup: keys (a '*' at either end is a
// glob) → completer spec.
@(private = "file")
CompletionRule :: struct {
	patterns: []string,
	spec:     string,
}

// Action words offered after `spec`'s command (hidden synonyms left out).
@(private = "file")
action_words :: proc(spec: WayuCommandSpec) -> []CompletionWord {
	words := make([dynamic]CompletionWord, context.temp_allocator)
	for a in spec.actions {
		if len(a.desc) > 0 {
			append(&words, CompletionWord{a.word, a.desc})
		}
	}
	return words[:]
}

// Flags offered after `spec`'s command: its own visible flags and --json.
@(private = "file")
flag_words :: proc(spec: WayuCommandSpec) -> []CompletionWord {
	words := make([dynamic]CompletionWord, context.temp_allocator)
	for f in spec.flags {
		if len(f.desc) > 0 {
			append(&words, CompletionWord{f.flag, f.desc})
		}
	}
	if spec.json != {} {
		append(&words, CompletionWord{"--json", "Machine-readable output"})
	}
	return words[:]
}

// Global flags offered after the command (`top` adds the ones only valid
// before it).
@(private = "file")
global_flag_words :: proc(top: bool) -> []CompletionWord {
	words := make([dynamic]CompletionWord, context.temp_allocator)
	for g in WAYU_GLOBAL_FLAGS {
		if g.top_only != top {
			continue
		}
		for f in g.flags {append(&words, CompletionWord{f, g.desc})}
	}
	return words[:]
}

// "CMD FLAG" keys (canonical command name) of the flags that take a value;
// global ones as "* FLAG".
@(private = "file")
flag_rules :: proc() -> []CompletionRule {
	rules := make([dynamic]CompletionRule, context.temp_allocator)
	for fv in WAYU_FLAG_VALUES {
		spec := find_command_spec(fv.command)
		if spec == nil {
			continue
		}
		keys := make([]string, 1, context.temp_allocator)
		keys[0] = fmt.tprintf("%s %s", spec.names[0], fv.flag)
		append(&rules, CompletionRule{keys, value_spec(fv.value)})
	}
	for g in WAYU_GLOBAL_FLAGS {
		if g.value == .NONE {
			continue
		}
		keys := make([dynamic]string, context.temp_allocator)
		for f in g.flags {append(&keys, fmt.tprintf("* %s", f))}
		append(&rules, CompletionRule{keys[:], value_spec(g.value)})
	}
	return rules[:]
}

// "CMD ACTION N" keys (canonical command name, every action word, "-" for
// a command without actions; N the 1-based argument, "*" every one, "--"
// after `--`): the `arg_names` entries first, then WAYU_ARG_COMPLETERS;
// exact positions before "*" so they win.
@(private = "file")
arg_rules :: proc() -> []CompletionRule {
	exact := make([dynamic]CompletionRule, context.temp_allocator)
	every := make([dynamic]CompletionRule, context.temp_allocator)
	add :: proc(
		exact, every: ^[dynamic]CompletionRule,
		spec: WayuCommandSpec,
		actions: bit_set[Action],
		position: int,
		completer: string,
	) {
		pos :=
			"*" if \
				position == ARG_EVERY else \
				"--" if position == ARG_AFTER_DASHDASH else fmt.tprint(position)
		keys := make([dynamic]string, context.temp_allocator)
		if actions == {} {
			append(&keys, fmt.tprintf("%s - %s", spec.names[0], pos))
		}
		for a in spec.actions {
			if actions != {} && a.action in actions {
				append(&keys, fmt.tprintf("%s %s %s", spec.names[0], a.word, pos))
			}
		}
		append(every if position == ARG_EVERY else exact, CompletionRule{keys[:], completer})
	}
	for spec in WAYU_COMMAND_SPECS {
		if spec.arg_names != .NONE {
			add(&exact, &every, spec, spec.arg_name_actions, 1, value_spec(.NAMES, spec.arg_names))
		}
	}
	for c in WAYU_ARG_COMPLETERS {
		spec := find_command_spec(c.command)
		if spec != nil {
			add(&exact, &every, spec^, c.actions, c.position, value_spec(c.value, c.names))
		}
	}
	append(&exact, ..every[:])
	return exact[:]
}

// A case pattern for bash/zsh: the key double-quoted, a '*' at either end
// left outside as a glob. Keys are command/action/flag words (no quotes).
@(private = "file")
sh_pattern :: proc(key: string) -> string {
	if strings.has_prefix(key, "*") {
		return fmt.tprintf("*\"%s\"", key[1:])
	}
	if strings.has_suffix(key, "*") {
		return fmt.tprintf("\"%s\"*", key[:len(key) - 1])
	}
	return fmt.tprintf("\"%s\"", key)
}

// bash/zsh `case` branches setting `spec`, from `rules`.
@(private = "file")
write_sh_rules :: proc(b: ^strings.Builder, rules: []CompletionRule) {
	for r in rules {
		strings.write_string(b, "        ")
		for k, i in r.patterns {
			if i > 0 {
				strings.write_byte(b, '|')
			}
			strings.write_string(b, sh_pattern(k))
		}
		fmt.sbprintf(b, ") spec=%s ;;\n", shell_single_quote(r.spec, context.temp_allocator))
	}
	strings.write_string(b, "        *) spec= ;;\n")
}

// bash/zsh: `_wayu_cmd WORD` sets cmd to the canonical command name ('?'
// when unknown) and act to '-' for a command without action words.
@(private = "file")
write_sh_cmd :: proc(b: ^strings.Builder) {
	strings.write_string(b, "_wayu_cmd() {\n    case \"$1\" in\n")
	for spec in WAYU_COMMAND_SPECS {
		fmt.sbprintf(
			b,
			"        %s) cmd=%s%s ;;\n",
			strings.join(spec.names, "|", context.temp_allocator),
			spec.names[0],
			"" if len(spec.actions) > 0 else " act=-",
		)
	}
	strings.write_string(b, "        *) cmd='?' act=- ;;\n    esac\n}\n\n")
}

// zsh `_describe` entries ('word:desc'), one per line.
@(private = "file")
write_zsh_describe :: proc(b: ^strings.Builder, words: []CompletionWord, indent: string) {
	for w in words {
		fmt.sbprintf(
			b,
			"%s%s\n",
			indent,
			shell_single_quote(fmt.tprintf("%s:%s", w.word, w.desc), context.temp_allocator),
		)
	}
}

// zsh completion for wayu (an fpath `_wayu` file). Allocated; caller deletes.
//
// The line is parsed, not indexed by position (OKAMI-355): global flags and
// their values may come anywhere, the first other word is the command, the
// next the action, then the arguments; flags complete at any position and
// `--` ends them. Bash and fish run the same parse.
generate_wayu_completion_zsh :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)

	strings.write_string(&b, "#compdef wayu\n\n")
	strings.write_string(&b, "# wayu completion script - Auto-generated\n")
	strings.write_string(&b, "# Regenerate with: wayu completions generate\n\n")

	strings.write_string(&b, "_wayu_commands() {\n    local -a commands\n    commands=(\n")
	for spec in WAYU_COMMAND_SPECS {
		for name in spec.names {
			fmt.sbprintf(
				&b,
				"        %s\n",
				shell_single_quote(fmt.tprintf("%s:%s", name, spec.desc), context.temp_allocator),
			)
		}
	}
	strings.write_string(&b, "    )\n    _describe -t commands 'wayu command' commands\n}\n\n")

	write_sh_cmd(&b)

	strings.write_string(&b, "_wayu_actions() {\n    local -a acts\n    case \"$1\" in\n")
	for spec in WAYU_COMMAND_SPECS {
		words := action_words(spec)
		if len(words) == 0 {
			continue
		}
		fmt.sbprintf(&b, "        %s) acts=(\n", spec.names[0])
		write_zsh_describe(&b, words, "            ")
		strings.write_string(&b, "        ) ;;\n")
	}
	strings.write_string(
		&b,
		"    esac\n    (( ${#acts} )) && _describe -t actions \"$1 action\" acts\n}\n\n",
	)

	strings.write_string(&b, "_wayu_flags() {\n    local -a flags\n    flags=(\n")
	write_zsh_describe(&b, global_flag_words(false), "        ")
	strings.write_string(&b, "    )\n    case \"$1\" in\n        '') flags+=(\n")
	write_zsh_describe(&b, global_flag_words(true), "            ")
	strings.write_string(&b, "        ) ;;\n")
	for spec in WAYU_COMMAND_SPECS {
		words := flag_words(spec)
		if len(words) == 0 {
			continue
		}
		fmt.sbprintf(&b, "        %s) flags+=(\n", spec.names[0])
		write_zsh_describe(&b, words, "            ")
		strings.write_string(&b, "        ) ;;\n")
	}
	strings.write_string(&b, "    esac\n    _describe -t flags 'flag' flags\n}\n\n")

	strings.write_string(&b, "# Sets spec: what the value of flag $2 (command $1) completes to.\n")
	strings.write_string(&b, "_wayu_flag() {\n    case \"$1 $2\" in\n")
	write_sh_rules(&b, flag_rules())
	strings.write_string(&b, "    esac\n}\n\n")

	strings.write_string(&b, "# Sets spec: what argument \"CMD ACTION N\" completes to.\n")
	strings.write_string(&b, "_wayu_arg() {\n    case \"$1\" in\n")
	write_sh_rules(&b, arg_rules())
	strings.write_string(&b, "    esac\n}\n\n")

	strings.write_string(
		&b,
		`# Existing entries, listed by the binary core.zsh records in _WAYU_BIN.
_wayu_names() {
    local -a names
    names=( ${(f)"$(command "${_WAYU_BIN:-wayu}" completions names "$@" 2>/dev/null)"} )
    (( ${#names} )) && compadd -a names
}

# Complete spec $1 ($2: the previous argument).
_wayu_spec() {
    local -a vals
    case "$1" in
        w:*) vals=( ${=1#w:} ); compadd -a vals ;;
        n:*) _wayu_names "${1#n:}" ;;
        N:*) _wayu_names "${1#N:}" "$2" ;;
        d) _path_files -/ ;;
        f) _files ;;
    esac
}

_wayu() {
    local cur="${words[CURRENT]}" w cmd= act= vf= spec= prev=
    integer i=2 n=0 dd=0 ddi=0
    while (( i < CURRENT )); do
        w="${words[i]}"
        (( i++ ))
        if (( dd )); then (( dd++ )); continue; fi
        if [[ -n $vf ]]; then vf=; continue; fi
        case "$w" in
            --) dd=1; ddi=$i ;;
            -*=*) ;;
            -*) _wayu_flag "$cmd" "$w"; [[ -n $spec ]] && vf=$w ;;
            *)
                if [[ -z $cmd ]]; then _wayu_cmd "$w"
                elif [[ -z $act ]]; then act=$w
                else (( n++ )); prev=${(Q)w}
                fi ;;
        esac
    done
    if [[ -n $vf ]]; then
        _wayu_flag "$cmd" "$vf"; _wayu_spec "$spec" "$prev"; return
    fi
    if [[ $cur == -*=* ]]; then
        _wayu_flag "$cmd" "${cur%%=*}"
        [[ -n $spec ]] && { compset -P '*='; _wayu_spec "$spec" "$prev"; }
        return
    fi
    if (( dd )); then
        _wayu_arg "$cmd $act --"
        if [[ $spec == c ]]; then
            words=( "${(@)words[ddi,-1]}" )
            (( CURRENT -= ddi - 1 ))
            _normal
        else
            _wayu_spec "$spec" "$prev"
        fi
        return
    fi
    if [[ $cur == -* ]]; then _wayu_flags "$cmd"; return; fi
    if [[ -z $cmd ]]; then _wayu_commands; return; fi
    [[ $cmd == '?' ]] && return
    if [[ -z $act ]]; then _wayu_actions "$cmd"; return; fi
    _wayu_arg "$cmd $act $(( n + 1 ))"
    if [[ -z $spec && $act == - ]]; then _wayu_flags "$cmd"; return; fi
    _wayu_spec "$spec" "$prev"
}

# Standard #compdef dispatch: when compinit autoloads this file as the
# _wayu function, run the completer immediately (otherwise the very first
# TAB only defines functions and completes nothing). When the file is
# sourced directly, register it with compdef instead.
if [[ $zsh_eval_context[-1] == loadautofunc ]]; then
    _wayu "$@"
else
    compdef _wayu wayu
fi
`,
	)
	return strings.to_string(b)
}

// Words of `words`, space-separated.
@(private = "file")
join_words :: proc(words: []CompletionWord) -> string {
	b := strings.builder_make(context.temp_allocator)
	for w, i in words {
		if i > 0 {
			strings.write_byte(&b, ' ')
		}
		strings.write_string(&b, w.word)
	}
	return strings.to_string(b)
}

// bash completion for wayu (sourced by core.bash from completions/wayu.bash).
// bash 3.2 compatible. Same parse as the zsh script.
generate_wayu_completion_bash :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "#!/usr/bin/env bash\n\n")
	strings.write_string(&b, "# wayu bash completion script - Auto-generated\n")
	strings.write_string(&b, "# Regenerate with: wayu completions generate\n\n")

	write_sh_cmd(&b)

	strings.write_string(&b, "# Sets acts (words after the command) and cflags (its flags).\n")
	strings.write_string(&b, "_wayu_words() {\n    acts= cflags=\n    case \"$1\" in\n")
	names := make([dynamic]CompletionWord, context.temp_allocator)
	for spec in WAYU_COMMAND_SPECS {
		for n in spec.names {append(&names, CompletionWord{n, spec.desc})}
	}
	fmt.sbprintf(
		&b,
		"        '') acts=\"%s\" cflags=\"%s\" ;;\n",
		join_words(names[:]),
		join_words(global_flag_words(true)),
	)
	for spec in WAYU_COMMAND_SPECS {
		acts := action_words(spec)
		flags := flag_words(spec)
		if len(acts) == 0 && len(flags) == 0 {
			continue
		}
		fmt.sbprintf(
			&b,
			"        %s) acts=\"%s\" cflags=\"%s\" ;;\n",
			spec.names[0],
			join_words(acts),
			join_words(flags),
		)
	}
	fmt.sbprintf(&b, "    esac\n    gflags=\"%s\"\n}\n\n", join_words(global_flag_words(false)))

	strings.write_string(&b, "# Sets spec: what the value of flag $2 (command $1) completes to.\n")
	strings.write_string(&b, "_wayu_flag() {\n    case \"$1 $2\" in\n")
	write_sh_rules(&b, flag_rules())
	strings.write_string(&b, "    esac\n}\n\n")

	strings.write_string(&b, "# Sets spec: what argument \"CMD ACTION N\" completes to.\n")
	strings.write_string(&b, "_wayu_arg() {\n    case \"$1\" in\n")
	write_sh_rules(&b, arg_rules())
	strings.write_string(&b, "    esac\n}\n\n")

	strings.write_string(
		&b,
		`# Existing entries of kind $1 matching $2 ($3: extra argument), listed by
# the binary core.bash records in _WAYU_BIN, matched by prefix and quoted
# with %q (compgen -W would expand a stored "$HOME/bin").
_wayu_names() {
    local n
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        case "$n" in "$2"*) COMPREPLY+=("$(printf '%q' "$n")") ;; esac
    done < <(command "${_WAYU_BIN:-wayu}" completions names "$1" ${3:+"$3"} 2>/dev/null)
}

# Complete spec $1 for word $2 ($3: the previous argument; $4: words after
# --, the current one included).
_wayu_spec() {
    case "$1" in
        w:*) COMPREPLY=($(compgen -W "${1#w:}" -- "$2")) ;;
        n:*) _wayu_names "${1#n:}" "$2" ;;
        N:*) _wayu_names "${1#N:}" "$2" "$3" ;;
        d) COMPREPLY=($(compgen -d -- "$2")) ;;
        f) COMPREPLY=($(compgen -f -- "$2")) ;;
        c)
            if [ "${4:-1}" -le 1 ]; then
                COMPREPLY=($(compgen -c -- "$2"))
            else
                COMPREPLY=($(compgen -f -- "$2"))
            fi ;;
    esac
}

_wayu_completion() {
    local cur="${COMP_WORDS[COMP_CWORD]}" w cmd="" act="" vf="" spec="" prev=""
    local acts="" cflags="" gflags="" i=1 n=0 dd=0
    COMPREPLY=()
    while [ "$i" -lt "$COMP_CWORD" ]; do
        w="${COMP_WORDS[i]}"
        i=$((i + 1))
        if [ "$dd" -gt 0 ]; then dd=$((dd + 1)); continue; fi
        if [ -n "$vf" ]; then vf=""; continue; fi
        case "$w" in
            --) dd=1 ;;
            -*=*) ;;
            -*)
                _wayu_flag "$cmd" "$w"
                [ -n "$spec" ] || continue
                # COMP_WORDBREAKS splits --flag=value into --flag = value.
                if [ "${COMP_WORDS[i]}" = "=" ]; then
                    if [ $((i + 1)) -ge "$COMP_CWORD" ]; then
                        [ "$cur" = "=" ] && cur=""
                        _wayu_spec "$spec" "$cur" "$prev"
                        return 0
                    fi
                    i=$((i + 2))
                else
                    vf="$w"
                fi ;;
            *)
                if [ -z "$cmd" ]; then
                    _wayu_cmd "$w"
                elif [ -z "$act" ]; then
                    act="$w"
                else
                    n=$((n + 1))
                    prev="$w"
                fi ;;
        esac
    done
    if [ -n "$vf" ]; then
        _wayu_flag "$cmd" "$vf"
        _wayu_spec "$spec" "$cur" "$prev"
        return 0
    fi
    case "$cur" in
        -*=*)
            # '=' is not in COMP_WORDBREAKS: the word keeps its --flag= prefix.
            _wayu_flag "$cmd" "${cur%%=*}"
            if [ -n "$spec" ]; then
                _wayu_spec "$spec" "${cur#*=}" "$prev"
                [ ${#COMPREPLY[@]} -gt 0 ] && COMPREPLY=("${COMPREPLY[@]/#/${cur%%=*}=}")
            fi
            return 0 ;;
    esac
    if [ "$dd" -gt 0 ]; then
        _wayu_arg "$cmd $act --"
        _wayu_spec "$spec" "$cur" "$prev" "$dd"
        return 0
    fi
    _wayu_words "$cmd"
    case "$cur" in
        -*) COMPREPLY=($(compgen -W "$cflags $gflags" -- "$cur")); return 0 ;;
    esac
    [ "$cmd" = "?" ] && return 0
    if [ -z "$cmd" ] || [ -z "$act" ]; then
        COMPREPLY=($(compgen -W "$acts" -- "$cur"))
        return 0
    fi
    _wayu_arg "$cmd $act $((n + 1))"
    if [ -z "$spec" ] && [ "$act" = "-" ]; then
        COMPREPLY=($(compgen -W "$cflags" -- "$cur"))
        return 0
    fi
    _wayu_spec "$spec" "$cur" "$prev"
}

complete -F _wayu_completion wayu
`,
	)
	return strings.to_string(b)
}

// fish `printf '%s\t%s\n' word desc ...` lines for `words`.
@(private = "file")
write_fish_words :: proc(b: ^strings.Builder, words: []CompletionWord, indent: string) {
	if len(words) == 0 {
		return
	}
	fmt.sbprintf(b, "%sprintf '%%s\\t%%s\\n'", indent)
	for w in words {
		fmt.sbprintf(
			b,
			" \\\n%s    %s %s",
			indent,
			escape_fish_string(w.word, context.temp_allocator),
			escape_fish_string(w.desc, context.temp_allocator),
		)
	}
	strings.write_byte(b, '\n')
}

// fish `switch` branches printing each rule's spec.
@(private = "file")
write_fish_rules :: proc(b: ^strings.Builder, rules: []CompletionRule) {
	for r in rules {
		strings.write_string(b, "        case")
		for k in r.patterns {
			fmt.sbprintf(b, " %s", escape_fish_string(k, context.temp_allocator))
		}
		fmt.sbprintf(
			b,
			"\n            echo %s\n",
			escape_fish_string(r.spec, context.temp_allocator),
		)
	}
}

// fish completion for wayu (completions/wayu.fish): one `__wayu_complete`
// function prints the candidates ("word<TAB>desc"); same parse as the zsh
// script.
generate_wayu_completion_fish :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "#!/usr/bin/env fish\n\n")
	strings.write_string(&b, "# wayu fish completion script - Auto-generated\n")
	strings.write_string(&b, "# Regenerate with: wayu completions generate\n\n")

	strings.write_string(&b, "function __wayu_commands\n")
	names := make([dynamic]CompletionWord, context.temp_allocator)
	for spec in WAYU_COMMAND_SPECS {
		for n in spec.names {append(&names, CompletionWord{n, spec.desc})}
	}
	write_fish_words(&b, names[:], "    ")
	strings.write_string(&b, "end\n\n")

	strings.write_string(&b, "# Canonical command name ('?' when unknown).\n")
	strings.write_string(&b, "function __wayu_cmd\n    switch $argv[1]\n")
	for spec in WAYU_COMMAND_SPECS {
		fmt.sbprintf(
			&b,
			"        case %s\n            echo %s\n",
			strings.join(spec.names, " ", context.temp_allocator),
			spec.names[0],
		)
	}
	strings.write_string(&b, "        case '*'\n            echo '?'\n    end\nend\n\n")

	strings.write_string(&b, "function __wayu_has_actions\n    switch $argv[1]\n        case")
	for spec in WAYU_COMMAND_SPECS {
		if len(spec.actions) > 0 {
			fmt.sbprintf(&b, " %s", spec.names[0])
		}
	}
	strings.write_string(&b, "\n            return 0\n    end\n    return 1\nend\n\n")

	strings.write_string(&b, "function __wayu_actions\n    switch $argv[1]\n")
	for spec in WAYU_COMMAND_SPECS {
		words := action_words(spec)
		if len(words) == 0 {
			continue
		}
		fmt.sbprintf(&b, "        case %s\n", spec.names[0])
		write_fish_words(&b, words, "            ")
	}
	strings.write_string(&b, "    end\nend\n\n")

	strings.write_string(&b, "function __wayu_flags\n")
	write_fish_words(&b, global_flag_words(false), "    ")
	strings.write_string(&b, "    switch \"$argv[1]\"\n        case ''\n")
	write_fish_words(&b, global_flag_words(true), "            ")
	for spec in WAYU_COMMAND_SPECS {
		words := flag_words(spec)
		if len(words) == 0 {
			continue
		}
		fmt.sbprintf(&b, "        case %s\n", spec.names[0])
		write_fish_words(&b, words, "            ")
	}
	strings.write_string(&b, "    end\nend\n\n")

	strings.write_string(
		&b,
		"# What the value of flag $argv[2] (command $argv[1]) completes to.\n",
	)
	strings.write_string(&b, "function __wayu_flag\n    switch \"$argv[1] $argv[2]\"\n")
	write_fish_rules(&b, flag_rules())
	strings.write_string(&b, "    end\nend\n\n")

	strings.write_string(&b, "# What argument \"CMD ACTION N\" completes to.\n")
	strings.write_string(&b, "function __wayu_arg\n    switch \"$argv[1]\"\n")
	write_fish_rules(&b, arg_rules())
	strings.write_string(&b, "    end\nend\n\n")

	strings.write_string(
		&b,
		`# Existing entries, listed by the binary core.fish records in _WAYU_BIN.
function __wayu_names
    set -l bin wayu
    test -n "$_WAYU_BIN"; and set bin $_WAYU_BIN
    command $bin completions names $argv 2>/dev/null
end

# Complete spec $argv[1] for token $argv[2] ($argv[3]: the previous argument).
function __wayu_spec
    switch "$argv[1]"
        case 'w:*'
            string split ' ' -- (string sub -s 3 -- $argv[1])
        case 'n:*'
            __wayu_names (string sub -s 3 -- $argv[1])
        case 'N:*'
            __wayu_names (string sub -s 3 -- $argv[1]) $argv[3]
        case d
            __fish_complete_directories $argv[2]
        case f
            __fish_complete_path $argv[2]
    end
end

function __wayu_complete
    set -l t (commandline -opc)
    set -e t[1]
    set -l cur (commandline -ct)
    set -l cmd
    set -l act
    set -l vf
    set -l prev
    set -l s
    set -l n 0
    set -l dd 0
    set -l ddi 0
    set -l i 0
    for w in $t
        set i (math $i + 1)
        if test $dd -gt 0
            set dd (math $dd + 1)
            continue
        end
        if test -n "$vf"
            set vf
            continue
        end
        switch $w
            case --
                set dd 1
                set ddi $i
            case '-*=*'
            case '-*'
                set s (__wayu_flag "$cmd" $w)
                test -n "$s"; and set vf $w
            case '*'
                if test -z "$cmd"
                    set cmd (__wayu_cmd $w)
                    __wayu_has_actions $cmd; or set act -
                else if test -z "$act"
                    set act $w
                else
                    set n (math $n + 1)
                    set prev $w
                end
        end
    end
    if test -n "$vf"
        set s (__wayu_flag "$cmd" $vf)
        __wayu_spec "$s" "$cur" "$prev"
        return
    end
    if string match -q -- '-*=*' "$cur"
        set -l f (string split -m 1 = -- "$cur")
        set s (__wayu_flag "$cmd" $f[1])
        test -n "$s"; or return
        for c in (__wayu_spec "$s" "$f[2]" "$prev")
            echo "$f[1]=$c"
        end
        return
    end
    if test $dd -gt 0
        set s (__wayu_arg "$cmd $act --")
        if test "$s" = c
            set -l sub $t
            set -e sub[1..$ddi]
            set -l line (string escape -- $sub)
            complete -C "$line $cur"
        else
            __wayu_spec "$s" "$cur" "$prev"
        end
        return
    end
    if string match -q -- '-*' "$cur"
        __wayu_flags "$cmd"
        return
    end
    if test -z "$cmd"
        __wayu_commands
        return
    end
    test "$cmd" = '?'; and return
    if test -z "$act"
        __wayu_actions $cmd
        return
    end
    set s (__wayu_arg "$cmd $act "(math $n + 1))
    if test -z "$s" -a "$act" = -
        __wayu_flags "$cmd"
        return
    end
    __wayu_spec "$s" "$cur" "$prev"
end

complete -c wayu -f -a '(__wayu_complete)'
`,
	)
	return strings.to_string(b)
}

// Generate completions for wayu itself
handle_completions_generate :: proc() {
	print_header("Generating wayu completions", "🎯")
	fmt.println()

	// Determine completions directory
	completions_dir := fmt.aprintf("%s/completions", wayu.data)
	defer delete(completions_dir)

	// Ensure directory exists
	if !os.exists(completions_dir) {
		err := os.make_directory(completions_dir)
		if err != nil {
			print_error("Failed to create completions directory: %v", err)
			wayu_exit(EXIT_CANTCREAT)
		}
	}

	// Write zsh completion file
	completion_path := fmt.aprintf("%s/_wayu", completions_dir)
	defer delete(completion_path)

	zsh_script := generate_wayu_completion_zsh()
	defer delete(zsh_script)
	write_ok := safe_write_file(completion_path, transmute([]byte)zsh_script)
	if !write_ok {
		print_error("Failed to write completion file")
		wayu_exit(EXIT_IOERR)
	}

	print_success("Generated: %s", completion_path)

	// Write bash completion file
	bash_completion_path := fmt.aprintf("%s/wayu.bash", completions_dir)
	defer delete(bash_completion_path)

	bash_script := generate_wayu_completion_bash()
	defer delete(bash_script)
	write_ok = safe_write_file(bash_completion_path, transmute([]byte)bash_script)
	if !write_ok {
		print_error("Failed to write bash completion file")
		wayu_exit(EXIT_IOERR)
	}

	print_success("Generated: %s", bash_completion_path)

	// Write fish completion file
	fish_completion_path := fmt.aprintf("%s/wayu.fish", completions_dir)
	defer delete(fish_completion_path)

	fish_script := generate_wayu_completion_fish()
	defer delete(fish_script)
	write_ok = safe_write_file(fish_completion_path, transmute([]byte)fish_script)
	if !write_ok {
		print_error("Failed to write fish completion file")
		wayu_exit(EXIT_IOERR)
	}

	print_success("Generated: %s", fish_completion_path)
	fmt.println()

	// Nothing to install: core.<ext> puts this dir on fpath (zsh), sources
	// wayu.bash (bash) and adds it to fish_complete_path (fish).
	print_info("Loaded by wayu's init in new shells (or now: exec $SHELL)")
}

// Generate bash completions for wayu
handle_completions_bash :: proc() {
	s := generate_wayu_completion_bash()
	defer delete(s)
	fmt.print(s)
}

// Generate fish completions for wayu
handle_completions_fish :: proc() {
	s := generate_wayu_completion_fish()
	defer delete(s)
	fmt.print(s)
}

// Generate zsh completions for wayu
handle_completions_zsh :: proc() {
	s := generate_wayu_completion_zsh()
	defer delete(s)
	fmt.print(s)
}

// Extended completions handler with generate action.
// All regular actions delegate to the main completions handler.
handle_completions_command_extended :: proc(action: Action, args: []string) {
	#partial switch action {
	case .ADD, .REMOVE, .RESTORE, .CLEAN, .DEDUP, .UNKNOWN:
		handle_completions_command(action, args)
	case .LIST:
		handle_completions_command(.LIST, args)
	case .HELP:
		print_completions_help()
	case .UPDATE:
		handle_completions_generate()
	case .CHECK:
		// bash
		handle_completions_bash()
	case .GET:
		// fish
		handle_completions_fish()
	case .TURBO:
		// zsh
		handle_completions_zsh()
	case .SEARCH:
		// names <kind> (hidden; used by the completion scripts)
		print_completion_names(len(args) > 0 ? args[0] : "", len(args) > 1 ? args[1] : "")
	case:
		handle_completions_command(action, args)
	}
}

// `wayu completions names <kind>`: existing entries, one per line, for
// the completion scripts (OKAMI-181/182). Read-only and quiet: an unknown
// kind or unreadable config prints nothing; the exit status is always 0
// (the scripts discard stderr).
print_completion_names :: proc(kind_word: string, arg := "") {
	kind := CompletionNames.NONE
	for word, k in COMPLETION_NAMES_KIND {
		if k != .NONE && word == kind_word {
			kind = k
		}
	}
	names := collect_completion_names(kind, arg)
	defer {
		for n in names {delete(n)}
		delete(names)
	}
	b := strings.builder_make(context.temp_allocator)
	for n in names {
		// One entry per line: a name containing a newline can't be offered.
		if strings.contains_any(n, "\r\n") {
			continue
		}
		strings.write_string(&b, n)
		strings.write_byte(&b, '\n')
	}
	fmt.print(strings.to_string(b))
}

// Existing entries of one kind, as the matching command accepts them:
// PATH entry dirs as stored, alias/constant names, plugin names, function
// names (functions/<name>.<ext>) and completion names (file name without
// the shell prefix/suffix), secret constant names, backup types (what
// `backup restore` takes: toml, entries and its synonyms, the backed-up
// shell startup files) and the backup numbers of type `arg`. Sorted (backup
// numbers in order). Allocated; caller deletes each and the array.
collect_completion_names :: proc(kind: CompletionNames, arg := "") -> [dynamic]string {
	out := make([dynamic]string)
	add_unique :: proc(out: ^[dynamic]string, s: string) {
		for e in out {
			if e == s {
				return
			}
		}
		append(out, strings.clone(s))
	}
	switch kind {
	case .NONE:
	case .PATH, .ALIAS, .CONSTANT, .SECRET:
		// Tab completion stays silent: a broken entries.json completes nothing.
		store, _, ok := entries_read()
		if !ok {
			break
		}
		defer entries_store_destroy(&store)
		#partial switch kind {
		case .PATH:
			for p in store.paths {add_unique(&out, p.dir)}
		case .ALIAS:
			for a in store.aliases {add_unique(&out, a.name)}
		case .CONSTANT:
			for e in store.env {add_unique(&out, e.name)}
		case .SECRET:
			for e in store.env {
				if e.secret {
					add_unique(&out, e.name)
				}
			}
		}
	case .PLUGIN:
		json_file := get_plugins_json_config_file()
		defer delete(json_file)
		if !os.exists(json_file) {
			break
		}
		config, ok := read_plugin_config_json()
		defer cleanup_plugin_config_json(&config)
		if ok {
			for p in config.plugins {add_unique(&out, p.name)}
		}
	case .FUNCTION, .COMPLETION:
		dir :=
			kind == .FUNCTION \
				? fmt.tprintf("%s/functions", wayu.data) \
				: fmt.tprintf("%s/completions", wayu.data)
		handle, err := os.open(dir)
		if err != nil {
			break
		}
		defer os.close(handle)
		infos, read_err := os.read_dir(handle, -1, context.allocator)
		if read_err != nil {
			break
		}
		defer os.file_info_slice_delete(infos, context.allocator)
		for info in infos {
			if info.type == .Directory {
				continue
			}
			name := info.name
			if kind == .FUNCTION {
				suffix := fmt.tprintf(".%s", wayu.shell_ext)
				if !strings.has_suffix(name, suffix) {
					continue
				}
				name = strings.trim_suffix(name, suffix)
			} else {
				if !is_completion_file(name) {
					continue
				}
				name = strings.trim_prefix(name, "_")
				for suffix in ([]string{".bash-completion", ".bash", ".fish"}) {
					if strings.has_suffix(name, suffix) {
						name = strings.trim_suffix(name, suffix)
						break
					}
				}
			}
			if len(name) > 0 {
				add_unique(&out, name)
			}
		}
	case .SCRIPT:
		for s in script_list_all() {add_unique(&out, s.name)}
	case .BACKUP:
		for t in ([]string{"toml", "entries", "path", "alias", "constants"}) {
			add_unique(&out, t)
		}
		keys := list_backup_keys()
		defer delete_backup_keys(keys)
		for k in keys {
			display := backup_key_display(k, context.temp_allocator)
			if f := startup_file_for_backup_name(display); len(f) > 0 {
				delete(f)
				add_unique(&out, display)
			}
		}
	case .BACKUP_INDEX:
		file := get_config_file_path(arg)
		defer delete(file)
		if len(file) == 0 {
			break
		}
		backups := list_backups_for_file(file)
		defer free_backup_infos(backups)
		for _, i in backups {add_unique(&out, fmt.tprint(i + 1))}
		return out
	}
	slice.sort(out[:])
	return out
}


// Returns the on-disk filename a completion should have for the current shell.
//
// If `name` already carries a conventional prefix/extension, keep it as-is
// — the user might be porting a completion file across shells and knows
// what they want. Otherwise apply the shell-specific convention:
//
//   zsh  → `_name`               (autoloaded via fpath + compinit)
//   bash → `name.bash-completion` (loop-sourced by core.bash)
//   fish → `name.fish`           (autoloaded via fish_complete_path)
completion_filename_for_shell :: proc(name: string, shell: ShellType) -> string {
	// Already in a recognized shell-specific form — respect it.
	if strings.has_prefix(name, "_") ||
	   strings.has_suffix(name, ".fish") ||
	   strings.has_suffix(name, ".bash") ||
	   strings.has_suffix(name, ".bash-completion") {
		return strings.clone(name)
	}

	switch shell {
	case .FISH:
		return fmt.aprintf("%s.fish", name)
	case .BASH:
		return fmt.aprintf("%s.bash-completion", name)
	case .ZSH, .UNKNOWN:
		return fmt.aprintf("_%s", name)
	}
	return strings.clone(name)
}

// Returns true if a directory entry looks like a completion file
// (any supported shell). Used by list/cleanup paths.
is_completion_file :: proc(filename: string) -> bool {
	if strings.contains(filename, ".backup.") do return false
	return(
		strings.has_prefix(filename, "_") ||
		strings.has_suffix(filename, ".fish") ||
		strings.has_suffix(filename, ".bash") ||
		strings.has_suffix(filename, ".bash-completion") \
	)
}

// Given a user-supplied name (e.g. "jj"), return the first matching completion
// file that actually exists in `dir`, trying every shell convention. Returns
// empty string if nothing matched. Caller owns the returned string.
find_existing_completion :: proc(dir, name: string) -> string {
	candidates := [?]string {
		name,
		fmt.tprintf("_%s", name),
		fmt.tprintf("%s.fish", name),
		fmt.tprintf("%s.bash", name),
		fmt.tprintf("%s.bash-completion", name),
	}
	for cand in candidates {
		full := fmt.aprintf("%s/%s", dir, cand)
		if os.exists(full) {
			return full
		}
		delete(full)
	}
	return ""
}

// Handle completions command
handle_completions_command :: proc(action: Action, args: []string) {
	#partial switch action {
	case .ADD:
		if len(args) < 2 {
			print_error_simple("Usage: wayu completions add <name> <source-file>")
			fmt.println("Example: wayu completions add jj /path/to/_jj")
			wayu_exit(EXIT_USAGE)
		}
		add_completion(args[0], args[1])
	case .REMOVE:
		if len(args) == 0 {
			print_error("Missing required argument: completion name")
			fmt.println()
			fmt.println("Usage: wayu completions rm <name>")
			fmt.println()
			fmt.println("Example:")
			fmt.println("  wayu completions rm jj")
			fmt.println()
			fmt.printfln(
				"%sHint:%s For interactive selection, use: %swayu --tui%s",
				get_muted(),
				RESET,
				get_primary(),
				RESET,
			)
			wayu_exit(EXIT_USAGE)
		}
		remove_completion(args[0])
	case .LIST:
		list_completions()
	case .GET:
		fmt.eprintln("ERROR: get action not supported for completions command")
		fmt.println("The get action only applies to plugins")
		wayu_exit(EXIT_USAGE)
	case .RESTORE:
		// RESTORE action is handled by backup command, not completions command
		fmt.eprintln("ERROR: restore action not supported for completions command")
		fmt.println("Use: wayu backup restore completions")
		wayu_exit(EXIT_USAGE)
	case .CLEAN:
		fmt.eprintln("ERROR: clean action not supported for completions command")
		fmt.println("The clean action only applies to path entries")
		wayu_exit(EXIT_USAGE)
	case .DEDUP:
		fmt.eprintln("ERROR: dedup action not supported for completions command")
		fmt.println("The dedup action only applies to path entries")
		wayu_exit(EXIT_USAGE)
	case .HELP:
		print_completions_help()
	case .UNKNOWN:
		fmt.eprintln("Unknown completions action")
		print_completions_help()
		wayu_exit(EXIT_USAGE)
	}
}

// Add completion from source file
add_completion :: proc(name: string, source_path: string) {
	// Validate source file exists
	if !os.exists(source_path) {
		print_error_with_context(.FILE_NOT_FOUND, source_path)
		wayu_exit(EXIT_NOINPUT)
	}

	// Normalize name with shell-appropriate convention (zsh `_foo`,
	// bash `foo.bash-completion`, fish `foo.fish`).
	completion_name := completion_filename_for_shell(name, wayu.shell)
	defer delete(completion_name)

	// Read source file
	content, read_ok := safe_read_file(source_path)
	if !read_ok {
		wayu_exit(EXIT_IOERR)
	}
	defer delete(content)

	// Destination directory
	completions_dir := fmt.aprintf("%s/completions", wayu.data)
	defer delete(completions_dir)

	// Ensure completions directory exists
	if !os.exists(completions_dir) {
		print_error_with_context(.CONFIG_NOT_INITIALIZED, wayu.config)
		wayu_exit(EXIT_CONFIG)
	}

	dest_path := fmt.aprintf("%s/%s", completions_dir, completion_name)
	defer delete(dest_path)

	// Check if already exists
	if os.exists(dest_path) {
		fmt.printfln(
			"%sWarning:%s Completion '%s' already exists. Overwriting.",
			WARNING,
			RESET,
			completion_name,
		)
	}

	// Dry-run mode check
	if wayu.dry_run {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.println()
		fmt.printfln("%sWould copy to completions directory:%s", BRIGHT_CYAN, RESET)
		fmt.printfln("  %s -> %s", source_path, dest_path)
		fmt.println()
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
		return
	}

	// Create backup before modifying
	if !create_backup_cli(dest_path) {
		wayu_exit(EXIT_IOERR)
	}

	// Write to destination
	write_ok := safe_write_file(dest_path, content)
	if !write_ok {
		wayu_exit(EXIT_IOERR)
	}

	// Cleanup old backups (keep last 5)
	cleanup_old_backups(dest_path, 5)

	print_success("Added completion: %s", completion_name)
	init_file := fmt.tprintf("%s/init.%s", wayu.data, wayu.shell_ext)
	fmt.printfln("\n%sNext steps:%s", BRIGHT_CYAN, RESET)
	fmt.printfln("  source %s", init_file)
	fmt.printfln("  or restart your shell")
}

// Remove completion file
remove_completion :: proc(name: string) {
	// Build directory path
	completions_dir := fmt.aprintf("%s/completions", wayu.data)
	defer delete(completions_dir)

	// Try shell-appropriate form first, then fall back to any other matching
	// convention so users don't need to remember underscores vs extensions.
	file_path := find_existing_completion(completions_dir, name)
	defer if file_path != "" do delete(file_path)

	if file_path == "" {
		print_error_simple("Completion not found: %s", name)
		fmt.printfln("\nRun %swayu completions list%s to see available completions", MUTED, RESET)
		wayu_exit(EXIT_NOINPUT)
	}

	// Extract just the filename for status messages.
	completion_name := file_path
	if slash := strings.last_index_byte(file_path, '/'); slash >= 0 {
		completion_name = file_path[slash + 1:]
	}

	// Dry-run mode check
	if wayu.dry_run {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
		fmt.println()
		fmt.printfln("%sWould remove completion file:%s", BRIGHT_CYAN, RESET)
		fmt.printfln("  %s", file_path)
		fmt.println()
		fmt.printfln("%sTo apply changes, remove --dry-run flag%s", MUTED, RESET)
		return
	}

	// Create backup before removing
	if !create_backup_cli(file_path) {
		wayu_exit(EXIT_IOERR)
	}

	// Remove file
	err := os.remove(file_path)
	if err != nil {
		print_error_simple("Failed to remove completion: %s", completion_name)
		wayu_exit(EXIT_IOERR)
	}

	// Cleanup old backups (keep last 5)
	cleanup_old_backups(file_path, 5)

	print_success("Removed completion: %s", completion_name)
}

// List all completions with metadata
list_completions :: proc() {
	// Check if wayu is initialized first
	if !check_wayu_initialized() {
		wayu_exit(EXIT_CONFIG)
	}

	completions_dir := fmt.aprintf("%s/completions", wayu.data)
	defer delete(completions_dir)

	// Check directory exists
	if !os.exists(completions_dir) {
		print_error_with_context(.CONFIG_NOT_INITIALIZED, wayu.config)
		wayu_exit(EXIT_CONFIG)
	}

	// Read directory
	dir_handle, err := os.open(completions_dir)
	if err != nil {
		print_error_simple("Failed to open completions directory")
		wayu_exit(EXIT_IOERR)
	}
	defer os.close(dir_handle)

	file_infos, read_err := os.read_dir(dir_handle, -1, context.allocator)
	if read_err != nil {
		print_error_simple("Failed to read completions directory")
		wayu_exit(EXIT_IOERR)
	}
	defer os.file_info_slice_delete(file_infos, context.allocator)

	// Filter completion files
	completion_files := make([dynamic]os.File_Info)
	defer delete(completion_files)

	for info in file_infos {
		if info.type == .Directory do continue
		if !is_completion_file(info.name) do continue
		append(&completion_files, info)
	}

	// Print header
	print_header("Shell Completions")
	fmt.println()

	if len(completion_files) == 0 {
		print_info("No completions installed")
		fmt.printfln(
			"\nAdd completions with: %swayu completions add <name> <source-file>%s",
			MUTED,
			RESET,
		)
		return
	}

	// Print each completion
	for info, i in completion_files {
		// Read first line for description
		file_path := fmt.aprintf("%s/%s", completions_dir, info.name)
		defer delete(file_path)

		first_line := ""
		content, content_err := os.read_entire_file(file_path, context.allocator)
		// first_line points into content (or the temp allocator): both must
		// outlive the print below, so free content at the end of the iteration.
		defer if content_err == nil {
			delete(content)
		}
		if content_err == nil {
			lines := strings.split(string(content), "\n", context.temp_allocator)
			if len(lines) > 0 {
				first_line = strings.trim_space(lines[0])
				if len(first_line) > 60 {
					first_line = fmt.tprintf("%s...", first_line[:60])
				}
			}
		}

		// Print completion info
		fmt.printf("  %s%s%d.%s ", MUTED, BOLD, i + 1, RESET)
		fmt.printf("%s%s%s", PRIMARY, info.name, RESET)

		// Size
		size_kb := f32(info.size) / 1024.0
		fmt.printf(" %s(%.1f KB)%s", MUTED, size_kb, RESET)

		fmt.println()

		if len(first_line) > 0 {
			fmt.printf("     %s%s%s\n", MUTED, first_line, RESET)
		}
	}

	fmt.printfln("\n%sTotal:%s %d completion(s)", BRIGHT_CYAN, RESET, len(completion_files))
}

// Help for completions command
print_completions_help :: proc() {
	// Title
	fmt.printf(
		"\n%s%swayu completions - Manage shell completions%s\n\n",
		BOLD,
		get_primary(),
		RESET,
	)

	// Usage section
	fmt.printf("%s%sUSAGE:%s\n", BOLD, get_secondary(), RESET)
	fmt.println("  wayu completions add <name> <source-file>    Add completion")
	fmt.println("  wayu completions remove <name>               Remove completion (alias: rm)")
	fmt.println("  wayu completions list                        List all completions (alias: ls)")
	fmt.println(
		"  wayu completions generate                    Write wayu's own completions (zsh, bash, fish)",
	)
	fmt.println("  wayu completions zsh|bash|fish               Print wayu's completion script")
	fmt.println("  wayu completions help                        Show this help")

	// Examples section
	fmt.printf("\n%s%sEXAMPLES:%s\n", BOLD, get_secondary(), RESET)
	fmt.printf("  %s# Add jujutsu completion%s\n", get_muted(), RESET)
	fmt.printf("  %swayu completions add jj /path/to/_jj%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# List all completions%s\n", get_muted(), RESET)
	fmt.printf("  %swayu completions list%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Remove a completion%s\n", get_muted(), RESET)
	fmt.printf("  %swayu completions rm jj%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf(
		"  %s# Generate _wayu, wayu.bash and wayu.fish, then follow the printed setup%s\n",
		get_muted(),
		RESET,
	)
	fmt.printf("  %swayu completions generate%s\n", get_muted(), RESET)

	// Notes section
	fmt.printf("\n%s%sNOTES:%s\n", BOLD, get_secondary(), RESET)
	fmt.printf(
		"  %s• Completion files are stored in ~/.local/share/wayu/completions/%s\n",
		get_muted(),
		RESET,
	)
	fmt.printf(
		"  %s• Naming follows the active shell: zsh `_name`, bash `name.bash-completion`, fish `name.fish`%s\n",
		get_muted(),
		RESET,
	)
	fmt.printf(
		"  %s• If the input already has a recognized form (_foo, foo.fish, ...) it is kept as-is%s\n",
		get_muted(),
		RESET,
	)
	fmt.printf(
		"  %s• Restart your shell or re-source the wayu init file after adding%s\n",
		get_muted(),
		RESET,
	)
	fmt.println()
}
