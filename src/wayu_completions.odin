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
	command: Command,
	names:   []string,
	desc:    string,
	// Action words (the word after the command). Empty: the command takes
	// no action word and every later word is an argument. `-h`/`--help`
	// always mean .HELP.
	actions: []WayuActionSpec,
	// Action when no action word is given.
	default_action: Action,
	// Flags the command's handler parses itself, beyond the global flags.
	flags: []WayuFlagSpec,
	// Actions whose output honors --json (OKAMI-239); --json anywhere else
	// is a usage error.
	json: bit_set[Action],
	// Accept any dash token (version/help never write).
	any_flag: bool,
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
}

// The <kind> word of `wayu completions names <kind>`.
COMPLETION_NAMES_KIND := [CompletionNames]string{
	.NONE       = "",
	.PATH       = "path",
	.ALIAS      = "alias",
	.CONSTANT   = "const",
	.PLUGIN     = "plugin",
	.FUNCTION   = "function",
	.COMPLETION = "completion",
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
WayuFlagSpec :: struct {
	flag: string,
	desc: string,
}

WAYU_COMMAND_SPECS := [?]WayuCommandSpec{
	{command = .PATH, names = {"path"}, desc = "Manage PATH entries", default_action = .LIST, json = {.LIST},
	 arg_names = .PATH, arg_name_actions = {.REMOVE, .GET},
	 actions = {
		{"add", .ADD, "Add a PATH entry"}, {"remove", .REMOVE, "Remove a PATH entry"},
		{"rm", .REMOVE, "Remove a PATH entry"}, {"list", .LIST, "List PATH entries"},
		{"ls", .LIST, "List PATH entries"}, {"get", .GET, "Get a PATH entry"},
		{"clean", .CLEAN, "Remove missing directories"}, {"dedup", .DEDUP, "Remove duplicates"},
		{"help", .HELP, "Show help"}}},
	{command = .ALIAS, names = {"alias"}, desc = "Manage shell aliases", default_action = .LIST, json = {.LIST},
	 arg_names = .ALIAS, arg_name_actions = {.REMOVE, .GET},
	 actions = {
		{"add", .ADD, "Add an alias"}, {"remove", .REMOVE, "Remove an alias"},
		{"rm", .REMOVE, "Remove an alias"}, {"list", .LIST, "List aliases"},
		{"ls", .LIST, "List aliases"}, {"get", .GET, "Get alias value"}, {"help", .HELP, "Show help"}}},
	{command = .CONSTANTS, names = {"constants", "const", "env"}, desc = "Manage environment constants",
	 default_action = .LIST, json = {.LIST}, arg_names = .CONSTANT, arg_name_actions = {.REMOVE, .GET},
	 actions = {
		{"add", .ADD, "Add a constant"}, {"remove", .REMOVE, "Remove a constant"},
		{"rm", .REMOVE, "Remove a constant"}, {"list", .LIST, "List constants"},
		{"ls", .LIST, "List constants"}, {"get", .GET, "Get constant value"}, {"help", .HELP, "Show help"}},
	 flags = {{"--reveal", "Show secret values unmasked in list"}}},
	{command = .SEARCH, names = {"search", "find", "f"}, desc = "Fuzzy search across all configs",
	 default_action = .LIST, json = {.LIST}},
	{command = .COMPLETIONS, names = {"completions"}, desc = "Manage shell completion scripts", default_action = .LIST,
	 arg_names = .COMPLETION, arg_name_actions = {.REMOVE},
	 actions = {
		{"add", .ADD, "Add a completion script"}, {"remove", .REMOVE, "Remove a completion"},
		{"rm", .REMOVE, "Remove a completion"}, {"list", .LIST, "List completions"},
		{"ls", .LIST, "List completions"}, {"generate", .UPDATE, "Generate wayu's own completions"},
		{"gen", .UPDATE, ""}, {"bash", .CHECK, "Print bash completion for wayu"},
		{"fish", .GET, "Print fish completion for wayu"}, {"zsh", .TURBO, "Print zsh completion for wayu"},
		{"names", .SEARCH, ""},
		{"help", .HELP, "Show help"}},
	 flags = {{"--generate", ""}, {"-g", ""}}},
	{command = .BACKUP, names = {"backup"}, desc = "Manage configuration backups", default_action = .LIST, json = {.LIST},
	 actions = {
		{"list", .LIST, "List backups"}, {"ls", .LIST, "List backups"},
		{"restore", .RESTORE, "Restore from backup"}, {"remove", .REMOVE, "Clean up old backups"},
		{"rm", .REMOVE, "Clean up old backups"}, {"help", .HELP, "Show help"}}},
	{command = .PLUGIN, names = {"plugin"}, desc = "Manage shell plugins", default_action = .LIST, json = {.LIST},
	 arg_names = .PLUGIN, arg_name_actions = {.REMOVE, .GET, .ENABLE, .DISABLE, .PRIORITY, .UPDATE},
	 actions = {
		{"add", .ADD, "Install a plugin"}, {"remove", .REMOVE, "Remove a plugin"},
		{"rm", .REMOVE, "Remove a plugin"}, {"list", .LIST, "List installed plugins"},
		{"ls", .LIST, "List installed plugins"}, {"get", .GET, "Show plugin info"},
		{"search", .SEARCH, "Browse popular plugins"}, {"enable", .ENABLE, "Enable a plugin"},
		{"disable", .DISABLE, "Disable a plugin"}, {"priority", .PRIORITY, "Set plugin load priority"},
		{"check", .CHECK, "Check for updates"}, {"update", .UPDATE, "Update plugins"},
		{"help", .HELP, "Show help"}},
	 flags = {
		{"--all", "Update all plugins"}, {"-a", ""},
		{"--category", "Filter 'plugin search' by category"}, {"-c", ""}, {"--category=", ""},
		{"--use", "Glob of files to load (plugin add)"}, {"--use=", ""}}},
	{command = .INIT, names = {"init"}, desc = "Initialize wayu configuration",
	 flags = {{"--template", "Apply a template after init"}, {"--template=", ""}}},
	{command = .CONFIG, names = {"config"}, desc = "Manage configuration files", default_action = .HELP,
	 actions = {
		{"edit", .UPDATE, "Edit wayu.toml in $EDITOR"}, {"extend", .ADD, "Edit extra config in $EDITOR"},
		{"e", .ADD, ""}, {"scan", .CHECK, "Detect shell config"}, {"s", .CHECK, ""},
		{"detect", .CHECK, ""}, {"help", .HELP, "Show help"}},
	 flags = {{"--fix", "Repair what 'config scan' found"}}},
	{command = .BUILD, names = {"build"}, desc = "Compile wayu.toml into shell init files", default_action = .LIST,
	 actions = {
		{"eval", .EVAL, "Regenerate and print shell code"}, {"turbo", .TURBO, "Generate turbo file"},
		{"profile", .CHECK, "Profile startup"}, {"clean", .CLEAN, "Clear the [tools] evalcache"},
		{"help", .HELP, "Show help"}}},
	{command = .EXPORT, names = {"export"}, desc = "Generate turbo export file", default_action = .TURBO,
	 actions = {
		{"turbo", .TURBO, "Generate turbo file"}, {"--turbo", .TURBO, ""},
		{"eval", .EVAL, "Output for eval"}, {"--eval", .EVAL, ""},
		{"check", .CHECK, "Check the turbo file is current"}, {"--check", .CHECK, ""},
		{"list", .LIST, "Show formats"}, {"ls", .LIST, "Show formats"}, {"help", .HELP, "Show help"}},
	 flags = {{"--turbo", ""}, {"--eval", ""}, {"--check", ""}}},
	{command = .TOML, names = {"toml"}, desc = "TOML configuration management", default_action = .CHECK,
	 actions = {
		{"validate", .CHECK, "Validate wayu.toml"},
		{"show", .GET, "Show config"}, {"keys", .LIST, "List keys"}, {"help", .HELP, "Show help"}},
	 flags = {{"--reveal", "Show secret values unmasked in show"}}},
	{command = .DOCTOR, names = {"doctor"}, desc = "Health check and diagnostics", default_action = .LIST, json = {.LIST},
	 flags = {
		{"--fix", "Repair what can be repaired"}, {"--profile", "Profile shell startup"},
		{"--optimize", "Suggest optimizations"}}},
	{command = .TEMPLATE, names = {"template"}, desc = "Configuration presets", default_action = .LIST,
	 actions = {
		{"list", .LIST, "List templates"}, {"ls", .LIST, "List templates"},
		{"apply", .ADD, "Apply a template"}, {"help", .HELP, "Show help"}}},
	{command = .HOOKS, names = {"hooks"}, desc = "Pre/post action hooks", default_action = .LIST,
	 actions = {
		{"list", .LIST, "List hooks"}, {"ls", .LIST, "List hooks"}, {"edit", .ADD, "Edit hooks"},
		{"help", .HELP, "Show help"}}},
	{command = .FUNCTION, names = {"function", "functions", "func", "fn"}, desc = "Manage custom shell functions",
	 default_action = .LIST, arg_names = .FUNCTION, arg_name_actions = {.ADD, .REMOVE},
	 actions = {
		{"add", .ADD, "Create a function in $EDITOR"}, {"edit", .ADD, "Edit a function"},
		{"new", .ADD, "Create a function"}, {"list", .LIST, "List functions"}, {"ls", .LIST, "List functions"},
		{"remove", .REMOVE, "Delete a function"}, {"rm", .REMOVE, "Delete a function"},
		{"delete", .REMOVE, "Delete a function"}, {"help", .HELP, "Show help"}}},
	{command = .RELOAD, names = {"reload", "watch", "hot-reload"}, desc = "Watch config files and regenerate init files"},
	{command = .VERSION, names = {"version"}, desc = "Show version", any_flag = true},
	{command = .HELP, names = {"help"}, desc = "Show help", any_flag = true},
}

// Row for a command word (a name or alias), nil when there is none.
find_command_spec_by_name :: proc(name: string) -> ^WayuCommandSpec {
	for &spec in WAYU_COMMAND_SPECS {
		for n in spec.names {
			if n == name { return &spec }
		}
	}
	return nil
}

// Row for a Command, nil for .UNKNOWN.
find_command_spec :: proc(command: Command) -> ^WayuCommandSpec {
	for &spec in WAYU_COMMAND_SPECS {
		if spec.command == command { return &spec }
	}
	return nil
}

// Action for an action word of `spec` (`-h`/`--help` always .HELP);
// .UNKNOWN when the command has no such word.
find_spec_action :: proc(spec: ^WayuCommandSpec, word: string) -> Action {
	if word == "-h" || word == "--help" { return .HELP }
	for a in spec.actions {
		if a.word == word { return a.action }
	}
	return .UNKNOWN
}

// Flags a command's handler parses itself (beyond the global flags in
// cli_parser). `-h`/`--help` are accepted everywhere; version/help (and an
// unknown command, reported as such) accept anything.
command_accepts_flag :: proc(command: Command, arg: string) -> bool {
	if arg == "-h" || arg == "--help" { return true }
	spec := find_command_spec(command)
	if spec == nil { return true }
	if spec.any_flag { return true }
	for f in spec.flags {
		if f.flag == arg { return true }
		if strings.has_suffix(f.flag, "=") && strings.has_prefix(arg, f.flag) { return true }
	}
	return false
}

// Whether `--json` means something for this command/action. Help and
// unknown actions/commands report their own outcome, so they don't
// reject it.
command_supports_json :: proc(command: Command, action: Action) -> bool {
	if action == .HELP || action == .UNKNOWN { return true }
	spec := find_command_spec(command)
	if spec == nil || spec.any_flag { return true }
	return action in spec.json
}

// "path list, alias list, …": the commands that honor --json, for help.
json_commands_summary :: proc(allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for spec in WAYU_COMMAND_SPECS {
		if spec.json == {} { continue }
		if len(spec.actions) == 0 {
			if strings.builder_len(b) > 0 { strings.write_string(&b, ", ") }
			strings.write_string(&b, spec.names[0])
			continue
		}
		for act in Action {
			if act not_in spec.json { continue }
			for a in spec.actions {
				if a.action != act || len(a.desc) == 0 { continue }
				if strings.builder_len(b) > 0 { strings.write_string(&b, ", ") }
				fmt.sbprintf(&b, "%s %s", spec.names[0], a.word)
				break
			}
		}
	}
	return strings.to_string(b)
}

// A word completions offer after a command: an action, a command flag, or
// --json.
@(private = "file")
CompletionWord :: struct {
	word: string,
	desc: string,
}

// Words offered after `spec`'s command (hidden synonyms left out).
// Temp-allocated.
@(private = "file")
completion_words :: proc(spec: WayuCommandSpec) -> []CompletionWord {
	words := make([dynamic]CompletionWord, context.temp_allocator)
	for a in spec.actions {
		if len(a.desc) > 0 { append(&words, CompletionWord{a.word, a.desc}) }
	}
	for f in spec.flags {
		if len(f.desc) > 0 { append(&words, CompletionWord{f.flag, f.desc}) }
	}
	if spec.json != {} {
		append(&words, CompletionWord{"--json", "Machine-readable output"})
	}
	return words[:]
}

// "CMD ACTION" pairs (every command name × every action word, synonyms
// included) whose first argument completes `spec.arg_names` entries.
// Temp-allocated.
@(private = "file")
arg_name_pairs :: proc(spec: WayuCommandSpec) -> []string {
	pairs := make([dynamic]string, context.temp_allocator)
	if spec.arg_names == .NONE { return pairs[:] }
	for name in spec.names {
		for a in spec.actions {
			if a.action in spec.arg_name_actions {
				append(&pairs, fmt.tprintf("%s %s", name, a.word))
			}
		}
	}
	return pairs[:]
}

// zsh completion for wayu (an fpath `_wayu` file). Allocated; caller deletes.
generate_wayu_completion_zsh :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	q :: proc(s: string) -> string { return shell_single_quote(s, context.temp_allocator) }

	strings.write_string(&b, "#compdef wayu\n\n")
	strings.write_string(&b, "# wayu completion script - Auto-generated\n")
	strings.write_string(&b, "# Regenerate with: wayu completions generate\n\n")

	strings.write_string(&b, "_wayu_commands() {\n    local -a commands\n    commands=(\n")
	for spec in WAYU_COMMAND_SPECS {
		for name in spec.names {
			fmt.sbprintf(&b, "        %s\n", q(fmt.tprintf("%s:%s", name, spec.desc)))
		}
	}
	strings.write_string(&b, "    )\n    _describe -t commands 'wayu command' commands\n}\n\n")

	strings.write_string(&b, "_wayu_actions() {\n    local -a actions\n    case \"$1\" in\n")
	for spec in WAYU_COMMAND_SPECS {
		words := completion_words(spec)
		if len(words) == 0 { continue }
		strings.write_string(&b, "        ")
		strings.write_string(&b, strings.join(spec.names, "|", context.temp_allocator))
		strings.write_string(&b, ") actions=(")
		for w in words {
			strings.write_byte(&b, ' ')
			strings.write_string(&b, q(fmt.tprintf("%s:%s", w.word, w.desc)))
		}
		strings.write_string(&b, " ) ;;\n")
	}
	strings.write_string(&b, "    esac\n    (( ${#actions} )) && _describe -t actions \"$1 action\" actions\n}\n\n")

	// Arguments: directories/files for `add`, existing entries (listed by
	// the binary core.zsh records in _WAYU_BIN) for the first argument of
	// rm/get/enable/... With `*::`, $line/$words hold the normal arguments
	// only, so the first argument after the action is CURRENT == 3.
	strings.write_string(&b, `_wayu_names() {
    local -a names
    names=( ${(f)"$(command "${_WAYU_BIN:-wayu}" completions names "$1" 2>/dev/null)"} )
    (( ${#names} )) && compadd -a names
}

_wayu_args() {
    case "$line[1] $line[2]" in
        "path add") _path_files -/ ;;
        "completions add") _files ;;
`)
	for spec in WAYU_COMMAND_SPECS {
		pairs := arg_name_pairs(spec)
		if len(pairs) == 0 { continue }
		strings.write_string(&b, "        ")
		for p, i in pairs {
			if i > 0 { strings.write_byte(&b, '|') }
			fmt.sbprintf(&b, "\"%s\"", p)
		}
		fmt.sbprintf(&b, ") (( CURRENT == 3 )) && _wayu_names %s ;;\n", COMPLETION_NAMES_KIND[spec.arg_names])
	}
	strings.write_string(&b, "    esac\n}\n\n")

	strings.write_string(&b, `# Main completion function
_wayu() {
    local curcontext="$curcontext" state line
    typeset -A opt_args

    _arguments -C \
        '(-h --help)'{-h,--help}'[Show help]' \
        '(-v --version)'{-v,--version}'[Show version]' \
        '(-n --dry-run)'{-n,--dry-run}'[Preview changes]' \
        '(-y --yes)'{-y,--yes}'[Skip confirmation]' \
        '--no-color[Disable colored output]' \
        '--tui[Launch TUI mode]' \
        '--shell[Specify shell]:shell:(zsh bash fish)' \
        '1: :_wayu_commands' \
        '2: :->action' \
        '*:: :->args'

    case "$state" in
        action)
            _wayu_actions "$line[1]"
            ;;
        args)
            _wayu_args
            ;;
    esac
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
`)
	return strings.to_string(b)
}

// bash completion for wayu (sourced by core.bash from completions/wayu.bash).
generate_wayu_completion_bash :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "#!/usr/bin/env bash\n\n")
	strings.write_string(&b, "# wayu bash completion script - Auto-generated\n")
	strings.write_string(&b, "# Regenerate with: wayu completions generate\n\n")
	strings.write_string(&b, "_wayu_completion() {\n")
	strings.write_string(&b, "    local cur=\"${COMP_WORDS[COMP_CWORD]}\" words=\"\"\n")
	strings.write_string(&b, "    COMPREPLY=()\n")
	strings.write_string(&b, "    if [ \"$COMP_CWORD\" -eq 1 ]; then\n        words=\"")
	first := true
	for spec in WAYU_COMMAND_SPECS {
		for name in spec.names {
			if !first { strings.write_byte(&b, ' ') }
			strings.write_string(&b, name)
			first = false
		}
	}
	strings.write_string(&b, " --help --version --dry-run --yes --no-color --tui --shell\"\n")
	strings.write_string(&b, "    elif [ \"$COMP_CWORD\" -eq 2 ]; then\n        case \"${COMP_WORDS[1]}\" in\n")
	for spec in WAYU_COMMAND_SPECS {
		words := completion_words(spec)
		if len(words) == 0 { continue }
		strings.write_string(&b, "            ")
		strings.write_string(&b, strings.join(spec.names, "|", context.temp_allocator))
		strings.write_string(&b, ") words=\"")
		for w, i in words {
			if i > 0 { strings.write_byte(&b, ' ') }
			strings.write_string(&b, w.word)
		}
		strings.write_string(&b, "\" ;;\n")
	}
	strings.write_string(&b, `        esac
    else
        case "${COMP_WORDS[1]} ${COMP_WORDS[2]}" in
            "path add") COMPREPLY=($(compgen -d -- "$cur")); return 0 ;;
            "completions add") COMPREPLY=($(compgen -f -- "$cur")); return 0 ;;
`)
	// Existing entries for the first argument of rm/get/enable/...
	// (OKAMI-181), listed by the binary core.bash records in _WAYU_BIN.
	for spec in WAYU_COMMAND_SPECS {
		pairs := arg_name_pairs(spec)
		if len(pairs) == 0 { continue }
		strings.write_string(&b, "            ")
		for p, i in pairs {
			if i > 0 { strings.write_byte(&b, '|') }
			fmt.sbprintf(&b, "\"%s\"", p)
		}
		fmt.sbprintf(&b, ") [ \"$COMP_CWORD\" -eq 3 ] && _wayu_names %s; return 0 ;;\n", COMPLETION_NAMES_KIND[spec.arg_names])
	}
	strings.write_string(&b, `        esac
    fi
    COMPREPLY=($(compgen -W "$words" -- "$cur"))
}

# Entries are matched by prefix and quoted with %q (compgen -W would expand
# a stored "$HOME/bin" instead of offering it).
_wayu_names() {
    local cur="${COMP_WORDS[COMP_CWORD]}" n
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        case "$n" in "$cur"*) COMPREPLY+=("$(printf '%q' "$n")") ;; esac
    done < <(command "${_WAYU_BIN:-wayu}" completions names "$1" 2>/dev/null)
}

complete -F _wayu_completion wayu
`)
	return strings.to_string(b)
}

// fish completion for wayu (completions/wayu.fish).
generate_wayu_completion_fish :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "#!/usr/bin/env fish\n\n")
	strings.write_string(&b, "# wayu fish completion script - Auto-generated\n")
	strings.write_string(&b, "# Regenerate with: wayu completions generate\n\n")

	strings.write_string(&b, "set -l commands")
	for spec in WAYU_COMMAND_SPECS {
		for name in spec.names { fmt.sbprintf(&b, " %s", name) }
	}
	strings.write_string(&b, "\n\n# Top-level completion (only when no subcommand has been entered yet)\n")
	strings.write_string(&b, "complete -c wayu -f\n")
	for spec in WAYU_COMMAND_SPECS {
		for name in spec.names {
			fmt.sbprintf(&b, "complete -c wayu -n \"not __fish_seen_subcommand_from $commands\" -a %s -d %s\n",
				name, escape_fish_string(spec.desc, context.temp_allocator))
		}
	}
	for spec in WAYU_COMMAND_SPECS {
		words := completion_words(spec)
		if len(words) == 0 { continue }
		cond := fmt.tprintf("__fish_seen_subcommand_from %s", strings.join(spec.names, " ", context.temp_allocator))
		// Action words only right after the command (flags anywhere), so
		// `wayu alias rm <TAB>` offers aliases, not actions again.
		action_cond := fmt.tprintf("%s; and test (count (commandline -opc)) -eq 2", cond)
		fmt.sbprintf(&b, "\n# %s\n", spec.names[0])
		for w in words {
			fmt.sbprintf(&b, "complete -c wayu -n %s -a %s -d %s\n",
				escape_fish_string(strings.has_prefix(w.word, "-") ? cond : action_cond, context.temp_allocator),
				escape_fish_string(w.word, context.temp_allocator),
				escape_fish_string(w.desc, context.temp_allocator))
		}
	}
	// Existing entries for the first argument of rm/get/enable/...
	// (OKAMI-182): `__wayu_arg1 CMD... -- ACTION...` is true when the
	// command line is exactly `wayu CMD ACTION` plus the word being typed.
	strings.write_string(&b, `
# Existing entries (first argument of rm/get/enable/...)
function __wayu_arg1
    set -l t (commandline -opc)
    test (count $t) -eq 3; or return 1
    set -l i (contains -i -- -- $argv); or return 1
    contains -- $t[2] $argv[1..(math $i - 1)]; or return 1
    contains -- $t[3] $argv[(math $i + 1)..-1]
end
`)
	for spec in WAYU_COMMAND_SPECS {
		if spec.arg_names == .NONE { continue }
		cond := strings.builder_make(context.temp_allocator)
		strings.write_string(&cond, "__wayu_arg1")
		for name in spec.names { fmt.sbprintf(&cond, " %s", name) }
		strings.write_string(&cond, " --")
		for a in spec.actions {
			if a.action in spec.arg_name_actions { fmt.sbprintf(&cond, " %s", a.word) }
		}
		fmt.sbprintf(&b, "complete -c wayu -n %s -a %s\n",
			escape_fish_string(strings.to_string(cond), context.temp_allocator),
			escape_fish_string(fmt.tprintf("(command wayu completions names %s 2>/dev/null)", COMPLETION_NAMES_KIND[spec.arg_names]), context.temp_allocator))
	}
	strings.write_string(&b, `
# Global flags
complete -c wayu -s h -l help -d "Show help"
complete -c wayu -s v -l version -d "Show version"
complete -c wayu -s n -l dry-run -d "Preview changes without writing"
complete -c wayu -s y -l yes -d "Skip confirmation prompts"
complete -c wayu -l tui -d "Launch interactive TUI mode"
complete -c wayu -l shell -x -a "zsh bash fish" -d "Specify shell type"
complete -c wayu -l no-color -d "Disable colored output"
`)
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
			os.exit(EXIT_CANTCREAT)
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
		os.exit(EXIT_IOERR)
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
		os.exit(EXIT_IOERR)
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
		os.exit(EXIT_IOERR)
	}

	print_success("Generated: %s", fish_completion_path)
	fmt.println()

	// Instructions
	print_section("Setup Instructions", EMOJI_INFO)
	fmt.println("The completion scripts have been generated. To enable them:")
	fmt.println()
	fmt.println("Zsh - Option 1 - Add to fpath (recommended):")
	fmt.printfln("  fpath=(%s $fpath)", completions_dir)
	fmt.println("  compinit")
	fmt.println()
	fmt.println("Zsh - Option 2 - Source directly in .zshrc:")
	fmt.printfln("  source %s", completion_path)
	fmt.println()
	fmt.println("Bash - Source in .bashrc:")
	fmt.printfln("  source %s", bash_completion_path)
	fmt.println()
	fmt.println("Fish - Symlink into completions dir:")
	fmt.printfln("  ln -sf %s ~/.config/fish/completions/wayu.fish", fish_completion_path)
	fmt.println()
	fmt.println("Then restart your shell or run:")
	fmt.println("  exec $SHELL")
	fmt.println()
	print_success("Tab completion now available: wayu <TAB>")
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
		for arg in args {
			if arg == "--generate" || arg == "-g" || arg == "generate" {
				handle_completions_generate()
				return
			}
		}
		handle_completions_command(.LIST, args)
	case .HELP:
		print_completions_help()
	case .UPDATE:
		handle_completions_generate()
	case .CHECK:  // bash
		handle_completions_bash()
	case .GET:    // fish
		handle_completions_fish()
	case .TURBO:  // zsh
		handle_completions_zsh()
	case .SEARCH: // names <kind> (hidden; used by the completion scripts)
		print_completion_names(len(args) > 0 ? args[0] : "")
	case:
		handle_completions_command(action, args)
	}
}

// `wayu completions names <kind>`: existing entries, one per line, for
// the completion scripts (OKAMI-181/182). Read-only and quiet: an unknown
// kind or unreadable config prints nothing; the exit status is always 0
// (the scripts discard stderr).
print_completion_names :: proc(kind_word: string) {
	kind := CompletionNames.NONE
	for word, k in COMPLETION_NAMES_KIND {
		if k != .NONE && word == kind_word { kind = k }
	}
	names := collect_completion_names(kind)
	defer {
		for n in names { delete(n) }
		delete(names)
	}
	b := strings.builder_make(context.temp_allocator)
	for n in names {
		// One entry per line: a name containing a newline can't be offered.
		if strings.contains_any(n, "\r\n") { continue }
		strings.write_string(&b, n)
		strings.write_byte(&b, '\n')
	}
	fmt.print(strings.to_string(b))
}

// Existing entries of one kind, as the matching command accepts them:
// [paths] values as written, [aliases]/[env] names, plugin names, function
// names (functions/<name>.<ext>) and completion names (file name without
// the shell prefix/suffix). Sorted. Allocated; caller deletes each and the
// array.
collect_completion_names :: proc(kind: CompletionNames) -> [dynamic]string {
	out := make([dynamic]string)
	add_unique :: proc(out: ^[dynamic]string, s: string) {
		for e in out { if e == s { return } }
		append(out, strings.clone(s))
	}
	switch kind {
	case .NONE:
	case .PATH:
		kvs := read_toml_section_kvs("paths")
		defer destroy_toml_kvs(&kvs)
		for kv in kvs {
			if len(strings.trim_space(kv.value)) > 0 { add_unique(&out, kv.value) }
		}
	case .ALIAS:
		kvs := read_toml_section_kvs("aliases")
		defer destroy_toml_kvs(&kvs)
		for kv in kvs { add_unique(&out, kv.key) }
	case .CONSTANT:
		kvs := read_toml_section_kvs("env")
		defer destroy_toml_kvs(&kvs)
		for kv in kvs { add_unique(&out, kv.key) }
	case .PLUGIN:
		json_file := get_plugins_json_config_file()
		defer delete(json_file)
		if !os.exists(json_file) { break }
		config, ok := read_plugin_config_json()
		defer cleanup_plugin_config_json(&config)
		if ok {
			for p in config.plugins { add_unique(&out, p.name) }
		}
	case .FUNCTION, .COMPLETION:
		dir := kind == .FUNCTION ? fmt.tprintf("%s/functions", wayu.config) : fmt.tprintf("%s/completions", wayu.data)
		handle, err := os.open(dir)
		if err != nil { break }
		defer os.close(handle)
		infos, read_err := os.read_dir(handle, -1, context.allocator)
		if read_err != nil { break }
		defer os.file_info_slice_delete(infos, context.allocator)
		for info in infos {
			if info.type == .Directory { continue }
			name := info.name
			if kind == .FUNCTION {
				suffix := fmt.tprintf(".%s", wayu.shell_ext)
				if !strings.has_suffix(name, suffix) { continue }
				name = strings.trim_suffix(name, suffix)
			} else {
				if !is_completion_file(name) { continue }
				name = strings.trim_prefix(name, "_")
				for suffix in ([]string{".bash-completion", ".bash", ".fish"}) {
					if strings.has_suffix(name, suffix) {
						name = strings.trim_suffix(name, suffix)
						break
					}
				}
			}
			if len(name) > 0 { add_unique(&out, name) }
		}
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
	return strings.has_prefix(filename, "_") ||
	       strings.has_suffix(filename, ".fish") ||
	       strings.has_suffix(filename, ".bash") ||
	       strings.has_suffix(filename, ".bash-completion")
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
			os.exit(EXIT_USAGE)
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
			fmt.printfln("%sHint:%s For interactive selection, use: %swayu --tui%s",
				get_muted(), RESET, get_primary(), RESET)
			os.exit(EXIT_USAGE)
		}
		remove_completion(args[0])
	case .LIST:
		list_completions()
	case .GET:
		fmt.eprintln("ERROR: get action not supported for completions command")
		fmt.println("The get action only applies to plugins")
		os.exit(EXIT_USAGE)
	case .RESTORE:
		// RESTORE action is handled by backup command, not completions command
		fmt.eprintln("ERROR: restore action not supported for completions command")
		fmt.println("Use: wayu backup restore completions")
		os.exit(EXIT_USAGE)
	case .CLEAN:
		fmt.eprintln("ERROR: clean action not supported for completions command")
		fmt.println("The clean action only applies to path entries")
		os.exit(EXIT_USAGE)
	case .DEDUP:
		fmt.eprintln("ERROR: dedup action not supported for completions command")
		fmt.println("The dedup action only applies to path entries")
		os.exit(EXIT_USAGE)
	case .HELP:
		print_completions_help()
	case .UNKNOWN:
		fmt.eprintln("Unknown completions action")
		print_completions_help()
		os.exit(EXIT_USAGE)
	}
}

// Add completion from source file
add_completion :: proc(name: string, source_path: string) {
	// Validate source file exists
	if !os.exists(source_path) {
		print_error_with_context(.FILE_NOT_FOUND, source_path)
		os.exit(EXIT_NOINPUT)
	}

	// Normalize name with shell-appropriate convention (zsh `_foo`,
	// bash `foo.bash-completion`, fish `foo.fish`).
	completion_name := completion_filename_for_shell(name, wayu.shell)
	defer delete(completion_name)

	// Read source file
	content, read_ok := safe_read_file(source_path)
	if !read_ok {
		os.exit(EXIT_IOERR)
	}
	defer delete(content)

	// Destination directory
	completions_dir := fmt.aprintf("%s/completions", wayu.data)
	defer delete(completions_dir)

	// Ensure completions directory exists
	if !os.exists(completions_dir) {
		print_error_with_context(.CONFIG_NOT_INITIALIZED, wayu.config)
		os.exit(EXIT_CONFIG)
	}

	dest_path := fmt.aprintf("%s/%s", completions_dir, completion_name)
	defer delete(dest_path)

	// Check if already exists
	if os.exists(dest_path) {
		fmt.printfln("%sWarning:%s Completion '%s' already exists. Overwriting.",
			WARNING, RESET, completion_name)
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
		os.exit(EXIT_IOERR)
	}

	// Write to destination
	write_ok := safe_write_file(dest_path, content)
	if !write_ok {
		os.exit(EXIT_IOERR)
	}

	// Cleanup old backups (keep last 5)
	cleanup_old_backups(dest_path, 5)

	print_success("Added completion: %s", completion_name)
	init_file := get_config_file_with_fallback("init", wayu.shell)
	defer delete(init_file)
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
		fmt.printfln("\nRun %swayu completions list%s to see available completions",
			MUTED, RESET)
		os.exit(EXIT_NOINPUT)
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
		os.exit(EXIT_IOERR)
	}

	// Remove file
	err := os.remove(file_path)
	if err != nil {
		print_error_simple("Failed to remove completion: %s", completion_name)
		os.exit(EXIT_IOERR)
	}

	// Cleanup old backups (keep last 5)
	cleanup_old_backups(file_path, 5)

	print_success("Removed completion: %s", completion_name)
}

// List all completions with metadata
list_completions :: proc() {
	// Check if wayu is initialized first
	if !check_wayu_initialized() {
		os.exit(EXIT_CONFIG)
	}

	completions_dir := fmt.aprintf("%s/completions", wayu.data)
	defer delete(completions_dir)

	// Check directory exists
	if !os.exists(completions_dir) {
		print_error_with_context(.CONFIG_NOT_INITIALIZED, wayu.config)
		os.exit(EXIT_CONFIG)
	}

	// Read directory
	dir_handle, err := os.open(completions_dir)
	if err != nil {
		print_error_simple("Failed to open completions directory")
		os.exit(EXIT_IOERR)
	}
	defer os.close(dir_handle)

	file_infos, read_err := os.read_dir(dir_handle, -1, context.allocator)
	if read_err != nil {
		print_error_simple("Failed to read completions directory")
		os.exit(EXIT_IOERR)
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
		fmt.printfln("\nAdd completions with: %swayu completions add <name> <source-file>%s",
			MUTED, RESET)
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
		defer if content_err == nil { delete(content) }
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
		fmt.printf("  %s%s%d.%s ", MUTED, BOLD, i+1, RESET)
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
	fmt.printf("\n%s%swayu completions - Manage shell completions%s\n\n", BOLD, get_primary(), RESET)

	// Usage section
	fmt.printf("%s%sUSAGE:%s\n", BOLD, get_secondary(), RESET)
	fmt.println("  wayu completions add <name> <source-file>    Add completion")
	fmt.println("  wayu completions remove <name>               Remove completion (alias: rm)")
	fmt.println("  wayu completions list                        List all completions (alias: ls)")
	fmt.println("  wayu completions generate                    Write wayu's own completions (zsh, bash, fish)")
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
	fmt.printf("  %s# Generate _wayu, wayu.bash and wayu.fish, then follow the printed setup%s\n", get_muted(), RESET)
	fmt.printf("  %swayu completions generate%s\n", get_muted(), RESET)

	// Notes section
	fmt.printf("\n%s%sNOTES:%s\n", BOLD, get_secondary(), RESET)
	fmt.printf("  %s• Completion files are stored in ~/.config/wayu/completions/%s\n", get_muted(), RESET)
	fmt.printf("  %s• Naming follows the active shell: zsh `_name`, bash `name.bash-completion`, fish `name.fish`%s\n", get_muted(), RESET)
	fmt.printf("  %s• If the input already has a recognized form (_foo, foo.fish, ...) it is kept as-is%s\n", get_muted(), RESET)
	fmt.printf("  %s• Restart your shell or re-source the wayu init file after adding%s\n", get_muted(), RESET)
	fmt.println()
}
