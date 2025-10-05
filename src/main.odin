package wayu

import "core:fmt"
import "core:os"
import "core:strings"
import "core:slice"
import "core:log"

HOME := os.get_env("HOME")
WAYU_CONFIG := fmt.aprintf("%s/.config/wayu", HOME)

Command :: enum {
	PATH,
	ALIAS,
	CONSTANTS,
	HELP,
	UNKNOWN,
}

Action :: enum {
	ADD,
	REMOVE,
	LIST,
	HELP,
	UNKNOWN,
}

ParsedArgs :: struct {
	command: Command,
	action:  Action,
	args:    []string,
}

main :: proc() {
	// Initialize logger for debug output
	when DEBUG {
		context.logger = log.create_console_logger(.Debug)
		defer log.destroy_console_logger(context.logger)
	}

	init_config_files()

	if len(os.args) < 2 {
		print_help()
		os.exit(1)
	}

	parsed := parse_args(os.args[1:])

	switch parsed.command {
	case .PATH:
		handle_path_command(parsed.action, parsed.args)
	case .ALIAS:
		handle_alias_command(parsed.action, parsed.args)
	case .CONSTANTS:
		handle_constants_command(parsed.action, parsed.args)
	case .HELP:
		print_help()
	case .UNKNOWN:
		fmt.eprintfln("Unknown command: %s", os.args[1])
		print_help()
		os.exit(1)
	}
}

parse_args :: proc(args: []string) -> ParsedArgs {
	parsed := ParsedArgs{}

	if len(args) == 0 {
		parsed.command = .HELP
		return parsed
	}

	// Parse command
	switch args[0] {
	case "path":
		parsed.command = .PATH
	case "alias":
		parsed.command = .ALIAS
	case "constants":
		parsed.command = .CONSTANTS
	case "help", "-h", "--help":
		parsed.command = .HELP
		return parsed
	case:
		parsed.command = .UNKNOWN
		return parsed
	}

	// Parse action
	if len(args) < 2 {
		parsed.action = .LIST
		return parsed
	}

	switch args[1] {
	case "add":
		parsed.action = .ADD
	case "remove", "rm":
		parsed.action = .REMOVE
	case "list", "ls":
		parsed.action = .LIST
	case "help", "-h", "--help":
		parsed.action = .HELP
	case:
		parsed.action = .UNKNOWN
		return parsed
	}

	// Parse remaining arguments
	if len(args) > 2 {
		parsed.args = args[2:]
	}

	return parsed
}

print_help :: proc() {
	print_header("wayu - Shell configuration management tool\n", EMOJI_PALM_TREE)

	print_section("USAGE:", EMOJI_USER)
	fmt.printf("  wayu <command> <action> [arguments]\n")
	fmt.println()

	print_section("COMMANDS:", EMOJI_COMMAND)
	print_item("", "path", "Manage PATH entries", EMOJI_PATH)
	print_item("", "alias", "Manage shell aliases", EMOJI_ALIAS)
	print_item("", "constants", "Manage environment constants", EMOJI_CONSTANT)
	print_item("", "help", "Show this help message", EMOJI_INFO)
	fmt.println()

	print_section("ACTIONS:", EMOJI_ACTION)
	print_item("", "add", "Add a new entry", EMOJI_ADD)
	print_item("", "remove, rm", "Remove an entry (interactive if no args)", EMOJI_REMOVE)
	print_item("", "list, ls", "List all entries", EMOJI_LIST)
	print_item("", "help", "Show command-specific help", EMOJI_INFO)
	fmt.println()

	print_section("EXAMPLES:", EMOJI_CYCLIST)
	fmt.printf("  wayu path add /usr/local/bin\n")
	fmt.printf("  wayu path add                    # Uses current directory\n")
	fmt.printf("  wayu path rm                     # Interactive removal\n")
	fmt.printf("  wayu alias add ll 'ls -la'\n")
	fmt.printf("  wayu alias rm                    # Interactive removal\n")
	fmt.printf("  wayu constants add MY_VAR value\n")
	fmt.printf("  wayu constants rm                # Interactive removal\n")
	fmt.println()
}
