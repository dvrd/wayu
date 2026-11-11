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
import "core:strings"

ParsedArgs :: struct {
	command:             Command,
	action:              Action,
	args:                []string,
	shell:               ShellType,
	tui:                 bool, // TUI mode flag

	// Component testing (PRP-13)
	component_test:      bool,
	component_name:      string,
	component_snapshot:  bool,
	component_verify:    bool,

	// Doctor options
	doctor_fix:          bool,
	doctor_json:         bool,
	doctor_profile:      bool,
	doctor_optimize:     bool,

	// List command options
	json_output:         bool, // --json flag for list commands
	source_filter:       string, // --source filter (wayu|external|inactive|all)

	// Flag validation (see check_unknown_flags). main() exits EXIT_USAGE
	// when `unknown_flag` is set and warns about `ambiguous_tail_flag`.
	unknown_flag:        string, // first `-x`/`--xyz` token no command accepts
	json_unsupported:    bool, // --json given to a command/action without JSON output
	ambiguous_tail_flag: string, // trailing short global flag kept in an add value
	bad_flag_value:      string, // "--shell bogus" style error (temp allocator); main exits EXIT_USAGE
	extra_arg:           string, // positional given to an action that takes none; main exits EXIT_USAGE
}

// Flag parsing state returned by parse_global_flags.
GlobalFlags :: struct {
	tui:                bool,
	component_test:     bool,
	component_name:     string,
	component_snapshot: bool,
	component_verify:   bool,
	json:               bool,
	// --reveal: position-independent like --full, but only commands whose
	// command_accepts_flag lists it (list views that mask secrets) take it.
	reveal:             bool,
	// --secret: `const add` only; like the trailing global long flags it
	// stays a flag at the end of an add value (`const add K v --secret`).
	secret:             bool,
	run_only:           bool, // --run-only (implies --secret)
	source_filter:      string,
	// The --full / -f / --source token given ("" if none), checked once the
	// command is known: only list views filter by source (OKAMI-353).
	source_flag:        string,
	// Indexes into filtered_args of dash tokens that were not consumed as
	// global flags and are not literal (after `--`, add value). Validated
	// against the command's own flags once the command is known.
	flag_like:          [dynamic]int,
	ambiguous_tail:     string,
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
	if len(positional) < 4 || positional[1] != "add" {
		return false
	}
	switch positional[0] {
	case "alias", "constants", "const", "env":
		return true
	}
	return false
}

// True when `positional` is exactly at the first value token of an add
// command (`alias add NAME <here>`): a dash token there is the value
// (`wayu const add OFFSET -5`), not an unknown flag.
@(private = "file")
at_add_value_head :: proc(positional: []string) -> bool {
	if len(positional) != 3 || positional[1] != "add" {
		return false
	}
	switch positional[0] {
	case "alias", "constants", "const", "env":
		return true
	}
	return false
}

// Global long flags that are still flags when they end argv, even inside an
// add value tail (rule 2 exception). `--secret` too, for `const` commands.
@(private = "file")
is_trailing_global_flag :: proc(arg: string, const_cmd := false) -> bool {
	switch arg {
	case "--dry-run", "--yes", "--json", "--no-color", "--no-colour":
		return true
	case "--secret", "--run-only":
		return const_cmd
	}
	return false
}

// Index in `args` where the trailing run of is_trailing_global_flag tokens
// starts (len(args) when there is none).
@(private = "file")
trailing_flags_start :: proc(args: []string) -> int {
	const_cmd := is_const_command(args)
	j := len(args)
	for j > 0 && is_trailing_global_flag(args[j - 1], const_cmd) {j -= 1}
	return j
}

// Is the command word (first non-flag token) `const` / `constants` / `env`?
@(private = "file")
is_const_command :: proc(args: []string) -> bool {
	switch first_command_word(args) {
	case "constants", "const", "env":
		return true
	}
	return false
}

// The first non-flag token ("" when there is none or `--` comes first).
@(private = "file")
first_command_word :: proc(args: []string) -> string {
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		if a == "--" {
			return ""
		}
		if (a == "--shell" || a == "--source") && i + 1 < len(args) {
			i += 1; continue
		}
		if is_simple_global_flag(a) {
			continue
		}
		return a
	}
	return ""
}

// Global flags that take no value (or carry it inline, `--source=x`/`-c=x`).
@(private = "file")
is_simple_global_flag :: proc(arg: string) -> bool {
	switch arg {
	case "--full",
	     "-f",
	     "--dry-run",
	     "-n",
	     "--yes",
	     "-y",
	     "--tui",
	     "--snapshot",
	     "--test",
	     "--json",
	     "--no-color",
	     "--no-colour",
	     "--reveal":
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
		if a == "--" {
			return false
		}
		if in_add_value_tail(positional[:]) {
			if i < tail_start {
				continue
			}
			return slice_contains(args[i:], flag)
		}
		if a == flag {
			return true
		}
		if (a == "--shell" || a == "--source") && i + 1 < len(args) {
			i += 1; continue
		}
		if is_simple_global_flag(a) {
			continue
		}
		append(&positional, a)
	}
	return false
}

// `--source` takes one of the list filters; anything else is a usage error
// (it used to show nothing, silently).
@(private = "file")
check_source_value :: proc(parsed: ^ParsedArgs, value: string) {
	switch value {
	case "wayu", "external", "inactive", "all":
	case:
		if len(parsed.bad_flag_value) == 0 {
			parsed.bad_flag_value = fmt.tprintf(
				"Invalid --source value '%s' (expected wayu, external, inactive or all)",
				value,
			)
		}
	}
}

// Parse global flags (--dry-run, --yes, --tui, --json, --no-color, --shell,
// --source, etc.) from raw CLI args. Returns the remaining (non-flag)
// arguments in `filtered_args`. Mutates `wayu` for side-effect flags.
@(private = "file")
parse_global_flags :: proc(
	args: []string,
	parsed: ^ParsedArgs,
	filtered_args: ^[dynamic]string,
) -> GlobalFlags {
	flags: GlobalFlags
	flags.source_filter = "wayu" // hide external by default; --full shows everything

	literal := false
	tail_start := trailing_flags_start(args)
	const_cmd := is_const_command(args)
	secrets_cmd := first_command_word(args) == "secrets" || first_command_word(args) == "secret"
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
			// `secrets run NAME... -- CMD`: the handler needs the split.
			if secrets_cmd {
				append(filtered_args, arg)
			}
			i += 1
			continue
		}
		switch {
		case arg == "--full" || arg == "-f":
			flags.source_filter = "all"
			flags.source_flag = arg
		case arg == "--dry-run" || arg == "-n":
			wayu.dry_run = true
		case arg == "--yes" || arg == "-y":
			wayu.yes_flag = true
		case arg == "--tui":
			flags.tui = true
		case strings.has_prefix(arg, "-c=") && len(filtered_args) == 0:
			// The dev component flag only before a command word:
			// `plugin search -c=dev` is the command's (OKAMI-351).
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
		case arg == "--secret" && const_cmd:
			flags.secret = true
		case arg == "--run-only" && const_cmd:
			flags.secret = true
			flags.run_only = true
		case strings.has_prefix(arg, "--source="):
			flags.source_filter = strings.trim_prefix(arg, "--source=")
			flags.source_flag = "--source"
			check_source_value(parsed, flags.source_filter)
		case arg == "--source" && i + 1 < len(args):
			flags.source_filter = args[i + 1]
			flags.source_flag = "--source"
			check_source_value(parsed, flags.source_filter)
			i += 1
		case arg == "--no-color" || arg == "--no-colour":
			set_plain_output()
		case arg == "--shell" && i + 1 < len(args):
			if sh := parse_shell_type(args[i + 1]); sh != .UNKNOWN {
				parsed.shell = sh
				set_active_shell(sh)
				shell_flag_given = true
			} else if len(parsed.bad_flag_value) == 0 {
				parsed.bad_flag_value = fmt.tprintf(
					"Invalid --shell value '%s' (expected zsh, bash or fish)",
					args[i + 1],
				)
			}
			i += 1
		case:
			// `-5` is a number (plugin priority), not a flag.
			is_number := len(arg) > 1 && arg[1] >= '0' && arg[1] <= '9'
			if len(arg) > 1 &&
			   arg[0] == '-' &&
			   !is_number &&
			   !at_add_value_head(filtered_args[:]) {
				append(&flags.flag_like, len(filtered_args))
			}
			append(filtered_args, arg)
		}
		i += 1
	}
	return flags
}

// Resolve command + action from filtered positional args. Populates
// `parsed.command`, `parsed.action`, and `parsed.args`. Command names and
// action words come from WAYU_COMMAND_SPECS (OKAMI-282).
@(private = "file")
parse_command_and_action :: proc(filtered_args: []string, parsed: ^ParsedArgs) {
	if len(filtered_args) == 0 {
		parsed.command = .HELP
		return
	}

	spec := find_command_spec_by_name(filtered_args[0])
	if spec == nil {
		switch filtered_args[0] {
		case "-v", "--version":
			parsed.command = .VERSION
		case "-h", "--help":
			parsed.command = .HELP
		case:
			parsed.command = .UNKNOWN
		}
		return
	}
	parsed.command = spec.command
	parsed.action = spec.default_action

	if spec.command == .DOCTOR {
		parse_doctor_flags(filtered_args, parsed)
		return
	}

	// The word after the command is its action. Commands without action
	// words (init, search, reload) get every word as an argument;
	// a leading help word still sets .HELP but stays in args for their
	// handlers.
	rest := filtered_args[1:]
	if len(rest) > 0 {
		has_actions := len(spec.actions) > 0
		if is_help_word(rest[0]) {
			parsed.action = .HELP
			if has_actions {
				rest = rest[1:]
			}
		} else if has_actions {
			parsed.action = find_spec_action(spec, rest[0])
			rest = rest[1:]
		}
	}
	if len(rest) > 0 {
		parsed.args = make([]string, len(rest))
		copy(parsed.args, rest)
	}
}

@(private = "file")
is_help_word :: proc(word: string) -> bool {
	return word == "help" || word == "-h" || word == "--help"
}

@(private = "file")
parse_doctor_flags :: proc(filtered_args: []string, parsed: ^ParsedArgs) {
	for i := 1; i < len(filtered_args); i += 1 {
		switch filtered_args[i] {
		case "--fix":
			parsed.doctor_fix = true
		case "--json":
			parsed.doctor_json = true
		case "--profile":
			parsed.doctor_profile = true
		case "--optimize":
			parsed.doctor_optimize = true
		case "--help", "-h", "help":
			print_doctor_usage()
			wayu_exit(0)
		case:
			// doctor takes no action words; dash tokens are checked by the
			// flag allow-list (command_accepts_flag).
			if !strings.has_prefix(filtered_args[i], "-") {
				print_error_simple("Unknown doctor argument: %s", filtered_args[i])
				print_doctor_usage()
				wayu_exit(EXIT_USAGE)
			}
		}
	}
}

parse_args :: proc(args: []string) -> ParsedArgs {
	parsed := ParsedArgs {
		shell = wayu.shell,
	}

	filtered_args := make([dynamic]string)
	defer delete(filtered_args)

	flags := parse_global_flags(args, &parsed, &filtered_args)
	defer delete(flags.flag_like)

	parsed.tui = flags.tui
	parsed.component_test = flags.component_test
	parsed.component_name = flags.component_name
	parsed.component_snapshot = flags.component_snapshot
	parsed.component_verify = flags.component_verify
	parsed.json_output = flags.json
	parsed.source_filter = flags.source_filter
	wayu.source_filter = flags.source_filter

	if flags.component_test {
		if len(filtered_args) > 0 {
			parsed.args = make([]string, len(filtered_args))
			copy(parsed.args, filtered_args[:])
		}
		return parsed
	}

	parse_command_and_action(filtered_args[:], &parsed)
	parsed.ambiguous_tail_flag = flags.ambiguous_tail
	// Flags that mean nothing for this command are usage errors, not
	// silently ignored (OKAMI-353): --snapshot/--test only go with -c=,
	// --full/--source only with the PATH/alias/const list views (and TUI).
	if flags.component_snapshot {
		parsed.unknown_flag = "--snapshot"
	} else if flags.component_verify {
		parsed.unknown_flag = "--test"
	} else if len(flags.source_flag) > 0 &&
	   !flags.tui &&
	   !source_filter_applies(parsed.command, parsed.action) {
		parsed.unknown_flag = flags.source_flag
	}
	for idx in flags.flag_like {
		// Position 0 is the command word itself (`--help`, `-v`, or an
		// unknown command reported as such).
		if idx == 0 || len(parsed.unknown_flag) > 0 {
			continue
		}
		if !command_accepts_flag(parsed.command, filtered_args[idx]) {
			parsed.unknown_flag = filtered_args[idx]
			break
		}
	}
	// --json where it means nothing is a usage error, not silently text.
	parsed.json_unsupported = flags.json && !command_supports_json(parsed.command, parsed.action)
	wayu.secret_flag = false
	wayu.run_only_flag = false
	if flags.secret {
		if parsed.command == .CONSTANTS && parsed.action == .ADD {
			wayu.secret_flag = true
			wayu.run_only_flag = flags.run_only
		} else if len(parsed.unknown_flag) == 0 {
			parsed.unknown_flag = "--run-only" if flags.run_only else "--secret"
		}
	}
	if len(parsed.args) > 0 && action_takes_no_args(parsed.command, parsed.action) {
		parsed.extra_arg = parsed.args[0]
		for a in parsed.args {
			if is_help_word(a) {
				parsed.extra_arg = "" // `path list --help` shows help
				break
			}
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

// The list views that filter rows by --full / --source.
@(private = "file")
source_filter_applies :: proc(command: Command, action: Action) -> bool {
	#partial switch command {
	case .PATH, .ALIAS, .CONSTANTS:
		return action == .LIST || action == .HELP
	}
	return false
}

// Actions that take no positional argument: a stray word (`path list x`,
// `secrets lock x`, `export eval check`) is a usage error (OKAMI-353).
@(private = "file")
action_takes_no_args :: proc(command: Command, action: Action) -> bool {
	#partial switch command {
	case .PATH, .ALIAS, .CONSTANTS, .PLUGIN, .SCRIPT, .FUNCTION, .HOOKS, .TEMPLATE, .COMPLETIONS:
		return action == .LIST
	case .SECRETS:
		return action == .LIST || action == .CLEAN
	case .EXPORT:
		return action != .HELP && action != .UNKNOWN
	case .TOML:
		return action == .CHECK || action == .GET || action == .LIST
	}
	return false
}

@(private = "file")
slice_contains :: proc(list: []string, s: string) -> bool {
	for x in list {
		if x == s {
			return true
		}
	}
	return false
}
