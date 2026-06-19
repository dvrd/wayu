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
}

// Flag parsing state returned by parse_global_flags.
GlobalFlags :: struct {
	tui:              bool,
	component_test:   bool,
	component_name:   string,
	component_snapshot: bool,
	component_verify: bool,
	json:             bool,
	source_filter:    string,
}

// Parse global flags (--dry-run, --yes, --tui, --json, --no-color, --shell,
// --source, etc.) from raw CLI args. Returns the remaining (non-flag)
// arguments in `filtered_args`. Mutates `wayu` for side-effect flags.
@(private = "file")
parse_global_flags :: proc(args: []string, parsed: ^ParsedArgs, filtered_args: ^[dynamic]string) -> GlobalFlags {
	flags: GlobalFlags
	flags.source_filter = "wayu"  // hide external by default; --full shows everything

	i := 0
	for i < len(args) {
		arg := args[i]
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
			wayu.shell = parsed.shell
			wayu.shell_ext = get_shell_extension(parsed.shell)
			// Re-derive filenames using the same static-string approach as
			// init_app_context (no heap allocation).
			switch parsed.shell {
			case .ZSH:
				wayu.path_file = "path.zsh"; wayu.alias_file = "aliases.zsh"
				wayu.constants_file = "constants.zsh"; wayu.init_file = "init.zsh"
				wayu.tools_file = "tools.zsh"
			case .BASH:
				wayu.path_file = "path.bash"; wayu.alias_file = "aliases.bash"
				wayu.constants_file = "constants.bash"; wayu.init_file = "init.bash"
				wayu.tools_file = "tools.bash"
			case .FISH:
				wayu.path_file = "path.fish"; wayu.alias_file = "aliases.fish"
				wayu.constants_file = "constants.fish"; wayu.init_file = "init.fish"
				wayu.tools_file = "tools.fish"
			case .UNKNOWN:
				wayu.path_file = "path.zsh"; wayu.alias_file = "aliases.zsh"
				wayu.constants_file = "constants.zsh"; wayu.init_file = "init.zsh"
				wayu.tools_file = "tools.zsh"
			}
			i += 1
		case:
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
		case "help", "-h", "--help": parsed.action = .HELP
		case:                   parsed.action = .UNKNOWN
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

@(private = "file")
parse_export_command :: proc(filtered_args: []string, parsed: ^ParsedArgs) {
	parsed.action = .TURBO
	if len(filtered_args) > 1 {
		switch filtered_args[1] {
		case "turbo":           parsed.action = .TURBO
		case "eval":            parsed.action = .EVAL
		case "list", "ls":      parsed.action = .LIST
		case "help", "-h", "--help": parsed.action = .HELP
		case:                   parsed.action = .TURBO
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
	return parsed
}
