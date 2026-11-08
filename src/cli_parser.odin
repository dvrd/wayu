// cli_parser.odin - `parse_args` and `ParsedArgs`
//
// Extracted from main.odin (2026-04-24) per code review L1. Owns CLI
// argument parsing: global flags (--dry-run, --yes, --json, --no-color,
// --shell, --tui, --source, --version, --help), command + action
// resolution, and doctor/component-test option flags.
//
// Pure parsing: `parse_args` returns a fully-populated `ParsedArgs` struct.
// The dispatch logic lives in main.odin's `main()` which interprets the
// parsed result and calls the appropriate `handle_*_command`.

package wayu

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "base:runtime"

ParsedArgs :: struct {
	command: Command,
	action:  Action,
	args:    []string,
	shell:   ShellType,
	tui:     bool,  // TUI mode flag

	// Component testing (PRP-13)
	component_test: bool,
	component_name: string,
	component_snapshot: bool,
	component_verify: bool,

	// Doctor options
	doctor_fix:      bool,
	doctor_json:     bool,
	doctor_profile:  bool,
	doctor_optimize: bool,

	// List command options
	json_output:     bool,  // --json flag for list commands
	source_filter:   string,  // --source filter (wayu|external|inactive|all)

	// Flag validation (see check_unknown_flags). main() exits EXIT_USAGE
	// when `unknown_flag` is set and warns about `ambiguous_tail_flag`.
	unknown_flag:        string, // first `-x`/`--xyz` token no command accepts
	ambiguous_tail_flag: string, // trailing short global flag kept in an add value
}

// Flag parsing state returned by parse_global_flags.
GlobalFlags :: struct {
	tui:              bool,
	component_test:   bool,
	component_name:   string,
	component_snapshot: bool,
	component_verify: bool,
	json:             bool,
	// --reveal: position-independent like --full, but only commands whose
	// command_accepts_flag lists it (list views that mask secrets) take it.
	reveal:           bool,
	source_filter:    string,
	// Indexes into filtered_args of dash tokens that were not consumed as
	// global flags and are not literal (after `--`, add value). Validated
	// against the command's own flags once the command is known.
	flag_like:        [dynamic]int,
	ambiguous_tail:   string,
}

// Where global flags are recognised (documented in `wayu help` → FLAGS):
//
//   1. `--` ends flag parsing: every later token is a literal positional
//      (the `--` itself is dropped). `wayu alias add x -- grep -n foo`
//   2. For value-taking adds (`alias add`, `const|constants|env add`), once
//      the name AND the first value token have been seen, the rest of argv
//      is part of the value. `wayu alias add gpf git push -f` keeps `-f`.
//      Flags may still go anywhere before the first value token
//      (`wayu alias add -n gc 'git commit'`).
//      Exception: global LONG flags at the very end of argv (`--dry-run`,
//      `--yes`, `--json`, `--no-color`) are flags, not value
//      (`wayu alias add x y --dry-run` previews). Put `--` before the value
//      to keep them: `wayu alias add hd -- helm install --dry-run`.
//   3. Everywhere else a global flag may appear in any position.
//   4. Any other `-x`/`--xyz` token outside a literal position (rule 1, the
//      add value) must be a flag the command itself accepts
//      (command_accepts_flag), else parsing fails with EXIT_USAGE so a typo
//      like `--dryrun` never silently performs a real write.
//
// True when `positional` (non-flag tokens seen so far) has reached the value
// tail of an add command, i.e. rule 2 applies to every following token.
@(private = "file")
in_add_value_tail :: proc(positional: []string) -> bool {
	if len(positional) < 4 || positional[1] != "add" { return false }
	switch positional[0] {
	case "alias", "constants", "const", "env": return true
	}
	return false
}

// True when `positional` is exactly at the first value token of an add
// command (`alias add NAME <here>`): a dash token there is the value
// (`wayu const add OFFSET -5`), not an unknown flag.
@(private = "file")
at_add_value_head :: proc(positional: []string) -> bool {
	if len(positional) != 3 || positional[1] != "add" { return false }
	switch positional[0] {
	case "alias", "constants", "const", "env": return true
	}
	return false
}

// Global long flags that are still flags when they end argv, even inside an
// add value tail (rule 2 exception).
@(private = "file")
is_trailing_global_flag :: proc(arg: string) -> bool {
	switch arg {
	case "--dry-run", "--yes", "--json", "--no-color", "--no-colour": return true
	}
	return false
}

// Index in `args` where the trailing run of is_trailing_global_flag tokens
// starts (len(args) when there is none).
@(private = "file")
trailing_flags_start :: proc(args: []string) -> int {
	j := len(args)
	for j > 0 && is_trailing_global_flag(args[j-1]) { j -= 1 }
	return j
}

// Global flags that take no value (or carry it inline, `--source=x`/`-c=x`).
@(private = "file")
is_simple_global_flag :: proc(arg: string) -> bool {
	switch arg {
	case "--full", "-f", "--dry-run", "-n", "--yes", "-y", "--tui",
	     "--snapshot", "--test", "--json", "--no-color", "--no-colour", "--reveal":
		return true
	}
	return strings.has_prefix(arg, "-c=") || strings.has_prefix(arg, "--source=")
}

// Cheap pre-scan used by main() before full parsing (arena sizing, color
// init): is `flag` present in a position where it counts as a global flag
// under the rules above?
global_flag_present :: proc(args: []string, flag: string) -> bool {
	positional := make([dynamic]string)
	defer delete(positional)
	tail_start := trailing_flags_start(args)
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		if a == "--" { return false }
		if in_add_value_tail(positional[:]) {
			if i < tail_start { continue }
			return slice_contains(args[i:], flag)
		}
		if a == flag { return true }
		if (a == "--shell" || a == "--source") && i + 1 < len(args) { i += 1; continue }
		if is_simple_global_flag(a) { continue }
		append(&positional, a)
	}
	return false
}

// Parse global flags (--dry-run, --yes, --tui, --json, --no-color, --shell,
// --source, etc.) from raw CLI args. Returns the remaining (non-flag)
// arguments in `filtered_args`. Mutates `wayu` for side-effect flags.
@(private = "file")
parse_global_flags :: proc(args: []string, parsed: ^ParsedArgs, filtered_args: ^[dynamic]string) -> GlobalFlags {
	flags: GlobalFlags
	flags.source_filter = "wayu"  // hide external by default; --full shows everything

	literal := false
	tail_start := trailing_flags_start(args)
	i := 0
	for i < len(args) {
		arg := args[i]
		value_tail := !literal && in_add_value_tail(filtered_args[:])
		if literal || (value_tail && i < tail_start) {
			// A short safety flag ending argv stays in the value (`grep -n`)
			// but is easy to mean as --dry-run / --yes: let main() warn.
			if value_tail && i == len(args) - 1 && (arg == "-n" || arg == "-y") {
				flags.ambiguous_tail = arg
			}
			append(filtered_args, arg)
			i += 1
			continue
		}
		if arg == "--" {
			literal = true
			i += 1
			continue
		}
		switch {
		case arg == "--full" || arg == "-f":
			flags.source_filter = "all"
		case arg == "--dry-run" || arg == "-n":
			wayu.dry_run = true
		case arg == "--yes" || arg == "-y":
			wayu.yes_flag = true
		case arg == "--tui":
			flags.tui = true
		case strings.has_prefix(arg, "-c="):
			flags.component_test = true
			flags.component_name = strings.trim_prefix(arg, "-c=")
		case arg == "--snapshot":
			flags.component_snapshot = true
		case arg == "--test":
			flags.component_verify = true
		case arg == "--json":
			flags.json = true
			wayu.json_output = true
		case arg == "--reveal":
			flags.reveal = true
		case strings.has_prefix(arg, "--source="):
			flags.source_filter = strings.trim_prefix(arg, "--source=")
		case arg == "--source" && i + 1 < len(args):
			flags.source_filter = args[i + 1]
			i += 1
		case arg == "--no-color" || arg == "--no-colour":
			CURRENT_COLOR_PROFILE = .ASCII
			RESET = ""
			BOLD = ""
			DIM = ""
			ITALIC = ""
			UNDERLINE = ""
		case arg == "--shell" && i + 1 < len(args):
			parsed.shell = parse_shell_type(args[i + 1])
			set_active_shell(parsed.shell)
			shell_flag_given = true
			i += 1
		case:
			// `-5` is a number (plugin priority), not a flag.
			is_number := len(arg) > 1 && arg[1] >= '0' && arg[1] <= '9'
			if len(arg) > 1 && arg[0] == '-' && !is_number && !at_add_value_head(filtered_args[:]) {
				append(&flags.flag_like, len(filtered_args))
			}
			append(filtered_args, arg)
		}
		i += 1
	}
	return flags
}

// Resolve command + action from filtered positional args. Populates
// `parsed.command`, `parsed.action`, and `parsed.args`.
@(private = "file")
parse_command_and_action :: proc(filtered_args: []string, parsed: ^ParsedArgs) {
	if len(filtered_args) == 0 {
		parsed.command = .HELP
		return
	}

	cmd := filtered_args[0]

	// Commands with complex subcommand / action parsing.
	switch cmd {
	case "path":       parsed.command = .PATH
	case "alias":      parsed.command = .ALIAS
	case "constants", "const", "env": parsed.command = .CONSTANTS
	case "backup":     parsed.command = .BACKUP
	case "plugin":     parsed.command = .PLUGIN
	case "init":
		parsed.command = .INIT
		if len(filtered_args) > 1 {
			if filtered_args[1] == "help" || filtered_args[1] == "-h" || filtered_args[1] == "--help" {
				parsed.action = .HELP
			}
			parsed.args = make([]string, len(filtered_args) - 1)
			copy(parsed.args, filtered_args[1:])
		}
		return
	case "migrate":
		parsed.command = .MIGRATE
		if len(filtered_args) > 1 {
			parsed.args = make([]string, len(filtered_args) - 1)
			copy(parsed.args, filtered_args[1:])
		}
		return
	case "config":
		parsed.command = .CONFIG
		parse_config_command(filtered_args, parsed)
		return
	case "build":
		parsed.command = .BUILD
		parse_build_command(filtered_args, parsed)
		return
	case "completions":
		parsed.command = .COMPLETIONS
		parse_completions_command(filtered_args, parsed)
		return
	case "export":
		parsed.command = .EXPORT
		parse_export_command(filtered_args, parsed)
		return
	case "toml":
		parsed.command = .TOML
		parse_toml_command(filtered_args, parsed)
		return
	case "version", "-v", "--version":
		parsed.command = .VERSION
		return
	case "help", "-h", "--help":
		parsed.command = .HELP
		return
	case "doctor":
		parsed.command = .DOCTOR
		parse_doctor_flags(filtered_args, parsed)
		return
	case "template":
		parsed.command = .TEMPLATE
		parse_template_command(filtered_args, parsed)
		return
	case "hooks":
		parsed.command = .HOOKS
		parse_hooks_command(filtered_args, parsed)
		return
	case "function", "func", "fn", "functions":
		parsed.command = .FUNCTION
		parse_function_command(filtered_args, parsed)
		return
	case "reload", "hot-reload", "watch":
		parsed.command = .RELOAD
		if len(filtered_args) > 1 {
			parsed.args = make([]string, len(filtered_args) - 1)
			copy(parsed.args, filtered_args[1:])
		}
		return
	case "search", "find", "f":
		parsed.command = .SEARCH
		if len(filtered_args) > 1 {
			parsed.args = make([]string, len(filtered_args) - 1)
			copy(parsed.args, filtered_args[1:])
		}
		return
	case:
		parsed.command = .UNKNOWN
		return
	}

	// Commands that reach here use a simple action as the second arg.
	if len(filtered_args) < 2 {
		parsed.action = .LIST
		return
	}

	action_str := filtered_args[1]
	switch action_str {
	case "add":              parsed.action = .ADD
	case "remove", "rm":    parsed.action = .REMOVE
	case "list", "ls":      parsed.action = .LIST
	case "get":             parsed.action = .GET
	case "check":           parsed.action = .CHECK
	case "update":          parsed.action = .UPDATE
	case "enable":          parsed.action = .ENABLE
	case "disable":         parsed.action = .DISABLE
	case "priority":        parsed.action = .PRIORITY
	case "search":          parsed.action = .SEARCH
	case "restore":         parsed.action = .RESTORE
	case "clean":           parsed.action = .CLEAN
	case "dedup":           parsed.action = .DEDUP
	case "turbo":           parsed.action = .TURBO
	case "eval":            parsed.action = .EVAL
	case "help", "-h", "--help":
		parsed.action = .HELP
	case:
		if action_str == "--help" || action_str == "-h" {
			parsed.action = .HELP
		} else {
			parsed.action = .UNKNOWN
			return
		}
	}

	if len(filtered_args) > 2 {
		parsed.args = make([]string, len(filtered_args) - 2)
		copy(parsed.args, filtered_args[2:])
	}
}

@(private = "file")
parse_config_command :: proc(filtered_args: []string, parsed: ^ParsedArgs) {
	if len(filtered_args) > 1 {
		switch filtered_args[1] {
		case "extend", "e":     parsed.action = .ADD
		case "edit":            parsed.action = .UPDATE
		case "scan", "s", "detect": parsed.action = .CHECK
		case "help", "-h", "--help": parsed.action = .HELP
		case:                   parsed.action = .UNKNOWN
		}
		if len(filtered_args) > 2 {
			parsed.args = make([]string, len(filtered_args) - 2)
			copy(parsed.args, filtered_args[2:])
		}
	} else {
		parsed.action = .HELP
	}
}

@(private = "file")
parse_build_command :: proc(filtered_args: []string, parsed: ^ParsedArgs) {
	if len(filtered_args) > 1 {
		switch filtered_args[1] {
		case "turbo":           parsed.action = .TURBO
		case "eval":            parsed.action = .EVAL
		case "profile":         parsed.action = .CHECK
		case "clean":           parsed.action = .CLEAN
		case "help", "-h", "--help": parsed.action = .HELP
		case:                   parsed.action = .UNKNOWN
		}
		if len(filtered_args) > 2 {
			parsed.args = make([]string, len(filtered_args) - 2)
			copy(parsed.args, filtered_args[2:])
		}
	} else {
		parsed.action = .LIST
	}
}

@(private = "file")
parse_completions_command :: proc(filtered_args: []string, parsed: ^ParsedArgs) {
	if len(filtered_args) > 1 {
		switch filtered_args[1] {
		case "add":             parsed.action = .ADD
		case "remove", "rm":    parsed.action = .REMOVE
		case "list", "ls":      parsed.action = .LIST
		case "generate", "gen": parsed.action = .UPDATE
		case "bash":            parsed.action = .CHECK
		case "fish":            parsed.action = .GET
		case "zsh":             parsed.action = .TURBO
		case "help", "-h", "--help": parsed.action = .HELP
		case:                   parsed.action = .UNKNOWN
		}
		if len(filtered_args) > 2 {
			parsed.args = make([]string, len(filtered_args) - 2)
			copy(parsed.args, filtered_args[2:])
		}
	} else {
		parsed.action = .LIST
	}
}

// `wayu export [turbo|eval|check|list|help]`; the documented flag forms
// (--turbo/--eval/--check) are the same modes (OKAMI-233). No mode = turbo.
// An unrecognised word is .UNKNOWN (usage error), never a silent turbo write.
@(private = "file")
parse_export_command :: proc(filtered_args: []string, parsed: ^ParsedArgs) {
	parsed.action = .TURBO
	if len(filtered_args) > 1 {
		switch filtered_args[1] {
		case "turbo", "--turbo":     parsed.action = .TURBO
		case "eval", "--eval":       parsed.action = .EVAL
		case "check", "--check":     parsed.action = .CHECK
		case "list", "ls":           parsed.action = .LIST
		case "help", "-h", "--help": parsed.action = .HELP
		case:                        parsed.action = .UNKNOWN
		}
		if len(filtered_args) > 2 {
			parsed.args = make([]string, len(filtered_args) - 2)
			copy(parsed.args, filtered_args[2:])
		}
	}
}

@(private = "file")
parse_toml_command :: proc(filtered_args: []string, parsed: ^ParsedArgs) {
	if len(filtered_args) > 1 {
		switch filtered_args[1] {
		case "validate":        parsed.action = .CHECK
		case "convert":         parsed.action = .UPDATE
		case "show":            parsed.action = .GET
		case "keys":            parsed.action = .LIST
		case "help", "-h", "--help": parsed.action = .HELP
		case:                   parsed.action = .UNKNOWN
		}
	} else {
		parsed.action = .LIST
	}
}

@(private = "file")
parse_doctor_flags :: proc(filtered_args: []string, parsed: ^ParsedArgs) {
	for i := 1; i < len(filtered_args); i += 1 {
		switch filtered_args[i] {
		case "--fix":      parsed.doctor_fix = true
		case "--json":     parsed.doctor_json = true
		case "--profile":  parsed.doctor_profile = true
		case "--optimize": parsed.doctor_optimize = true
		case "--help", "-h":
			print_doctor_usage()
			os.exit(0)
		}
	}
}

@(private = "file")
parse_template_command :: proc(filtered_args: []string, parsed: ^ParsedArgs) {
	if len(filtered_args) > 1 {
		switch filtered_args[1] {
		case "list", "ls":      parsed.action = .LIST
		case "apply":
			parsed.action = .ADD
			if len(filtered_args) > 2 {
				parsed.args = make([]string, len(filtered_args) - 2)
				copy(parsed.args, filtered_args[2:])
			}
		case "help", "-h", "--help": parsed.action = .HELP
		case:                   parsed.action = .UNKNOWN
		}
	} else {
		parsed.action = .LIST
	}
}

@(private = "file")
parse_hooks_command :: proc(filtered_args: []string, parsed: ^ParsedArgs) {
	if len(filtered_args) > 1 {
		switch filtered_args[1] {
		case "list", "ls":      parsed.action = .LIST
		case "edit":            parsed.action = .ADD
		case "help", "-h", "--help": parsed.action = .HELP
		case:                   parsed.action = .UNKNOWN
		}
	} else {
		parsed.action = .LIST
	}
}

@(private = "file")
parse_function_command :: proc(filtered_args: []string, parsed: ^ParsedArgs) {
	if len(filtered_args) > 1 {
		switch filtered_args[1] {
		case "add", "edit", "new":     parsed.action = .ADD
		case "remove", "rm", "delete": parsed.action = .REMOVE
		case "list", "ls":            parsed.action = .LIST
		case "help", "-h", "--help":   parsed.action = .HELP
		case:                         parsed.action = .UNKNOWN
		}
		if len(filtered_args) > 2 {
			parsed.args = make([]string, len(filtered_args) - 2)
			copy(parsed.args, filtered_args[2:])
		}
	} else {
		parsed.action = .LIST
	}
}

parse_args :: proc(args: []string) -> ParsedArgs {
	parsed := ParsedArgs{
		shell = wayu.shell,
	}

	filtered_args := make([dynamic]string)
	defer delete(filtered_args)

	flags := parse_global_flags(args, &parsed, &filtered_args)
	defer delete(flags.flag_like)

	parsed.tui              = flags.tui
	parsed.component_test   = flags.component_test
	parsed.component_name   = flags.component_name
	parsed.component_snapshot = flags.component_snapshot
	parsed.component_verify = flags.component_verify
	parsed.json_output      = flags.json
	parsed.source_filter    = flags.source_filter
	wayu.source_filter     = flags.source_filter

	if flags.component_test {
		if len(filtered_args) > 0 {
			parsed.args = make([]string, len(filtered_args))
			copy(parsed.args, filtered_args[:])
		}
		return parsed
	}

	parse_command_and_action(filtered_args[:], &parsed)
	parsed.ambiguous_tail_flag = flags.ambiguous_tail
	for idx in flags.flag_like {
		// Position 0 is the command word itself (`--help`, `-v`, or an
		// unknown command reported as such).
		if idx == 0 { continue }
		if !command_accepts_flag(parsed.command, filtered_args[idx]) {
			parsed.unknown_flag = filtered_args[idx]
			break
		}
	}
	wayu.reveal_secrets = false
	if flags.reveal {
		if command_accepts_flag(parsed.command, "--reveal") {
			wayu.reveal_secrets = true
		} else if len(parsed.unknown_flag) == 0 {
			parsed.unknown_flag = "--reveal"
		}
	}
	return parsed
}

// Flags a command's handler parses itself (beyond the global flags in
// parse_global_flags). `-h`/`--help` are accepted everywhere.
command_accepts_flag :: proc(command: Command, arg: string) -> bool {
	if arg == "-h" || arg == "--help" { return true }
	#partial switch command {
	case .DOCTOR:
		switch arg { case "--fix", "--profile", "--optimize": return true }
	case .MIGRATE:
		switch arg { case "--from", "--to", "--schema": return true }
	case .CONFIG:
		return arg == "--fix"
	case .COMPLETIONS:
		return arg == "--generate" || arg == "-g"
	case .PLUGIN:
		switch arg { case "--all", "-a", "--category", "-c": return true }
		return strings.has_prefix(arg, "--category=")
	case .EXPORT:
		switch arg { case "--eval", "--turbo", "--check": return true }
	case .CONSTANTS, .TOML:
		// `const list` / `toml show` mask secret-looking values unless asked.
		return arg == "--reveal"
	case .VERSION, .HELP, .UNKNOWN:
		// Nothing to protect: these never write.
		return true
	}
	return false
}

@(private = "file")
slice_contains :: proc(list: []string, s: string) -> bool {
	for x in list { if x == s { return true } }
	return false
}
