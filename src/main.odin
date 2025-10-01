package wayu

import "core:fmt"
import "core:os"
import "core:strings"
import "core:slice"

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
	print_header("wayu - Shell configuration management tool", EMOJI_ROCKET)

	print_section("USAGE")
	fmt.printf("  %swayu%s %s<command>%s %s<action>%s %s[arguments]%s\n\n",
		BOLD, RESET, PRIMARY, RESET, SECONDARY, RESET, MUTED, RESET)

	print_section("COMMANDS")
	print_item("", "path", "Manage PATH entries", EMOJI_PATH)
	print_item("", "alias", "Manage shell aliases", EMOJI_ALIAS)
	print_item("", "constants", "Manage environment constants", EMOJI_CONSTANT)
	print_item("", "help", "Show this help message", EMOJI_INFO)

	print_section("ACTIONS")
	print_item("", "add", "Add a new entry", EMOJI_ADD)
	print_item("", "remove, rm", "Remove an entry (interactive if no args)", EMOJI_REMOVE)
	print_item("", "list, ls", "List all entries", EMOJI_LIST)
	print_item("", "help", "Show command-specific help", EMOJI_INFO)

	print_section("EXAMPLES")
	fmt.printf("  %swayu path add /usr/local/bin%s\n", MUTED, RESET)
	fmt.printf("  %swayu path add%s                    %s# Uses current directory%s\n", MUTED, RESET, DIM, RESET)
	fmt.printf("  %swayu path rm%s                     %s# Interactive removal%s\n", MUTED, RESET, DIM, RESET)
	fmt.printf("  %swayu alias add ll 'ls -la'%s\n", MUTED, RESET)
	fmt.printf("  %swayu alias rm%s                    %s# Interactive removal%s\n", MUTED, RESET, DIM, RESET)
	fmt.printf("  %swayu constants add MY_VAR value%s\n", MUTED, RESET)
	fmt.printf("  %swayu constants rm%s                %s# Interactive removal%s\n", MUTED, RESET, DIM, RESET)
	fmt.println()
}
