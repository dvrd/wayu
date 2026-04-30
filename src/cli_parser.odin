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
import tui "tui"

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

parse_args :: proc(args: []string) -> ParsedArgs {
	parsed := ParsedArgs{
		shell = DETECTED_SHELL, // Default to detected shell
	}

	// Filter out flags and process them
	filtered_args := make([dynamic]string)
	defer delete(filtered_args)

	tui_flag := false
	component_test_flag := false
	component_name_str := ""
	snapshot_flag := false
	verify_flag := false
	no_color_flag := false
	json_flag := false
	source_filter := "all"

	i := 0
	for i < len(args) {
		arg := args[i]
		if arg == "--dry-run" || arg == "-n" {
			DRY_RUN = true
		} else if arg == "--yes" || arg == "-y" {
			YES_FLAG = true
		} else if arg == "--tui" {
			tui_flag = true
		} else if strings.has_prefix(arg, "-c=") {
			component_test_flag = true
			component_name_str = strings.trim_prefix(arg, "-c=")
		} else if arg == "--snapshot" {
			snapshot_flag = true
		} else if arg == "--test" {
			verify_flag = true
		} else if arg == "--json" {
			json_flag = true
			JSON_OUTPUT = true
		} else if strings.has_prefix(arg, "--source=") {
			source_filter = strings.trim_prefix(arg, "--source=")
		} else if arg == "--source" && i + 1 < len(args) {
			source_filter = args[i + 1]
			i += 1
		} else if arg == "--no-color" || arg == "--no-colour" {
			no_color_flag = true
			// Force ASCII color profile - affects output in this function
			CURRENT_COLOR_PROFILE = .ASCII
			// Reinitialize ANSI codes for ASCII mode
			RESET = ""
			BOLD = ""
			DIM = ""
			ITALIC = ""
			UNDERLINE = ""
		} else if arg == "--shell" && i + 1 < len(args) {
			// Parse shell override
			shell_name := args[i + 1]
			parsed.shell = parse_shell_type(shell_name)
			// Update global detected shell
			DETECTED_SHELL = parsed.shell
			// Update global shell extension for dry-run messages and file operations
			SHELL_EXT = get_shell_extension(parsed.shell)
			// Free old file name globals before reassigning (they were allocated by init_shell_globals)
			delete(PATH_FILE)
			delete(ALIAS_FILE)
			delete(CONSTANTS_FILE)
			delete(INIT_FILE)
			delete(TOOLS_FILE)
			// Also update the file name globals
			PATH_FILE = fmt.aprintf("path.%s", SHELL_EXT)
			ALIAS_FILE = fmt.aprintf("aliases.%s", SHELL_EXT)
			CONSTANTS_FILE = fmt.aprintf("constants.%s", SHELL_EXT)
			INIT_FILE = fmt.aprintf("init.%s", SHELL_EXT)
			TOOLS_FILE = fmt.aprintf("tools.%s", SHELL_EXT)
			i += 1 // Skip the shell value
		} else {
			append(&filtered_args, arg)
		}
		i += 1
	}

	// Assign global flags once here — every return path below inherits them.
	parsed.tui              = tui_flag
	parsed.component_test   = component_test_flag
	parsed.component_name   = component_name_str
	parsed.component_snapshot = snapshot_flag
	parsed.component_verify = verify_flag
	parsed.json_output      = json_flag
	parsed.source_filter    = source_filter
	SOURCE_FILTER           = source_filter

	// Handle component test mode early - all filtered args become component args.
	if component_test_flag {
		if len(filtered_args) > 0 {
			remaining_args := make([]string, len(filtered_args))
			copy(remaining_args, filtered_args[:])
			parsed.args = remaining_args
		}
		return parsed
	}

	if len(filtered_args) == 0 {
		parsed.command = .HELP
		return parsed
	}

	// Parse command.
	switch filtered_args[0] {
	case "path":       parsed.command = .PATH
	case "alias":      parsed.command = .ALIAS
	case "constants", "const", "env":  parsed.command = .CONSTANTS
	case "backup":     parsed.command = .BACKUP
	case "plugin":     parsed.command = .PLUGIN
	case "init":
		parsed.command = .INIT
		if len(filtered_args) > 1 {
			switch filtered_args[1] {
			case "help", "-h", "--help":
				parsed.action = .HELP
			}
			remaining_args := make([]string, len(filtered_args) - 1)
			copy(remaining_args, filtered_args[1:])
			parsed.args = remaining_args
		}
		return parsed
	case "migrate":
		parsed.command = .MIGRATE
		if len(filtered_args) > 1 {
			remaining := make([]string, len(filtered_args) - 1)
			copy(remaining, filtered_args[1:])
			parsed.args = remaining
		}
		return parsed
	case "config":
		parsed.command = .CONFIG
		// Parse config subcommand
		if len(filtered_args) > 1 {
			switch filtered_args[1] {
			case "extend", "e":
				parsed.action = .ADD  // Use ADD for extend (extra.zsh)
			case "edit":
				parsed.action = .UPDATE  // Use UPDATE for edit (wayu.toml)
			case "scan", "s", "detect":
				parsed.action = .CHECK  // Use CHECK for scan
			case "help", "-h", "--help":
				parsed.action = .HELP
			case:
				parsed.action = .UNKNOWN
			}
			// H5 fix (2026-04-24): forward any trailing args (e.g. `--fix`
			// on `wayu config scan --fix`) into parsed.args so the subcommand
			// handler can actually see them. Previously this was always
			// empty and `wayu config scan --fix` silently ran the read-only
			// scan path.
			if len(filtered_args) > 2 {
				remaining := make([]string, len(filtered_args) - 2)
				copy(remaining, filtered_args[2:])
				parsed.args = remaining
			}
		} else {
			parsed.action = .HELP // Default: show help
		}
		return parsed
	case "build":
		parsed.command = .BUILD
		// Parse build subcommand
		if len(filtered_args) > 1 {
			switch filtered_args[1] {
			case "turbo":
				parsed.action = .TURBO
			case "eval":
				parsed.action = .EVAL  // Use EVAL for --eval mode
			case "profile":
				parsed.action = .CHECK  // Use CHECK for profile
			case "help", "-h", "--help":
				parsed.action = .HELP
			case:
				parsed.action = .UNKNOWN
			}
		} else {
			parsed.action = .LIST // Default: standard build
		}
		return parsed
	case "completions":
		parsed.command = .COMPLETIONS
		if len(filtered_args) > 1 {
			switch filtered_args[1] {
			case "add":
				parsed.action = .ADD
			case "remove", "rm":
				parsed.action = .REMOVE
			case "list", "ls":
				parsed.action = .LIST
			case "generate", "gen":
				parsed.action = .UPDATE  // Use UPDATE for generate
			case "bash":
				parsed.action = .CHECK  // Use CHECK for bash
			case "fish":
				parsed.action = .GET    // Use GET for fish
			case "zsh":
				parsed.action = .TURBO  // Use TURBO for zsh
			case "help", "-h", "--help":
				parsed.action = .HELP
			case:
				parsed.action = .UNKNOWN
			}
			if len(filtered_args) > 2 {
				parsed.args = make([]string, len(filtered_args) - 2)
				copy(parsed.args, filtered_args[2:])
			}
		} else {
			parsed.action = .LIST
		}
		return parsed
	case "export":
		parsed.command = .EXPORT
		parsed.action = .TURBO // Default action for export is turbo
		// Capture sub-action and args for export
		if len(filtered_args) > 1 {
			// First arg after "export" is the action
			action_str := filtered_args[1]
			switch action_str {
			case "turbo":
				parsed.action = .TURBO
			case "eval":
				parsed.action = .EVAL
			case "list", "ls":
				parsed.action = .LIST
			case "help", "-h", "--help":
				parsed.action = .HELP
			case:
				// Unknown action - default to turbo
				parsed.action = .TURBO
			}
			// Capture remaining args after action
			if len(filtered_args) > 2 {
				parsed.args = make([]string, len(filtered_args) - 2)
				copy(parsed.args, filtered_args[2:])
			}
		}
		return parsed
	case "toml":
		parsed.command = .TOML
		// Parse toml subcommand
		if len(filtered_args) > 1 {
			switch filtered_args[1] {
			case "validate":
				parsed.action = .CHECK
			case "convert":
				parsed.action = .UPDATE
			case "show":
				parsed.action = .GET
			case "keys":
				parsed.action = .LIST
			case "help", "-h", "--help":
				parsed.action = .HELP
			case:
				parsed.action = .UNKNOWN
			}
		} else {
			parsed.action = .LIST // Default: list/info
		}
		return parsed
	case "version", "-v", "--version": parsed.command = .VERSION; return parsed
	case "help", "-h", "--help":       parsed.command = .HELP;    return parsed
	case "doctor":
		parsed.command = .DOCTOR
		// Parse doctor flags
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
		return parsed
	case "template":
		parsed.command = .TEMPLATE
		if len(filtered_args) > 1 {
			switch filtered_args[1] {
			case "list", "ls":
				parsed.action = .LIST
			case "apply":
				parsed.action = .ADD
				if len(filtered_args) > 2 {
					parsed.args = make([]string, len(filtered_args) - 2)
					copy(parsed.args, filtered_args[2:])
				}
			case "help", "-h", "--help":
				parsed.action = .HELP
			case:
				parsed.action = .UNKNOWN
			}
		} else {
			parsed.action = .LIST
		}
		return parsed
	case "hooks":
		parsed.command = .HOOKS
		if len(filtered_args) > 1 {
			switch filtered_args[1] {
			case "list", "ls":
				parsed.action = .LIST
			case "edit":
				parsed.action = .ADD
			case "help", "-h", "--help":
				parsed.action = .HELP
			case:
				parsed.action = .UNKNOWN
			}
		} else {
			parsed.action = .LIST
		}
		return parsed
	case "reload", "hot-reload", "watch":
		parsed.command = .RELOAD
		if len(filtered_args) > 1 {
			remaining_args := make([]string, len(filtered_args) - 1)
			copy(remaining_args, filtered_args[1:])
			parsed.args = remaining_args
		}
		return parsed
	case "search", "find", "f":
		parsed.command = .SEARCH
		// Capture query argument(s) for search
		if len(filtered_args) > 1 {
			remaining_args := make([]string, len(filtered_args) - 1)
			copy(remaining_args, filtered_args[1:])
			parsed.args = remaining_args
		}
		return parsed
	case:              parsed.command = .UNKNOWN; return parsed
	}

	// Parse action (commands that have sub-actions reach here).
	if len(filtered_args) < 2 {
		parsed.action = .LIST
		return parsed
	}

	switch filtered_args[1] {
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
		// Before returning UNKNOWN, check if this is a help flag for a subcommand
		if filtered_args[1] == "--help" || filtered_args[1] == "-h" {
			parsed.action = .HELP
		} else {
			parsed.action = .UNKNOWN
			return parsed
		}
	}

	// Remaining positional args (e.g. the path/name/value after the action).
	if len(filtered_args) > 2 {
		remaining_args := make([]string, len(filtered_args) - 2)
		copy(remaining_args, filtered_args[2:])
		parsed.args = remaining_args
	}

	return parsed
}
