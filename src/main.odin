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
	COMPLETIONS,
	INIT,
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
  context.logger = log.create_console_logger(.Debug, { .Level, .Terminal_Color })
  defer log.destroy_console_logger(context.logger)

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
	case .COMPLETIONS:
		handle_completions_command(parsed.action, parsed.args)
	case .INIT:
		handle_init_command()
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
	case "completions":
		parsed.command = .COMPLETIONS
	case "init":
		parsed.command = .INIT
		return parsed
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

update_zshrc :: proc(init_file: string) {
	home := os.get_env("HOME")
	zshrc_path := fmt.aprintf("%s/.zshrc", home)
	defer delete(zshrc_path)

	// Check if .zshrc exists
	if !os.exists(zshrc_path) {
		fmt.println("\nNo ~/.zshrc found. Create one and add the following line:")
		fmt.printfln("  source %s", init_file)
		return
	}

	// Read .zshrc
	data, read_ok := os.read_entire_file_from_filename(zshrc_path)
	if !read_ok {
		fmt.eprintfln("Error: Failed to read %s", zshrc_path)
		return
	}
	defer delete(data)

	content := string(data)

	// Check if wayu is already sourced
	source_line := fmt.aprintf("source \"%s\"", init_file)
	defer delete(source_line)

	alt_source_line := fmt.aprintf("source %s", init_file)
	defer delete(alt_source_line)

	alt_source_line2 := fmt.aprintf("source \"$HOME/.config/wayu/init.zsh\"")
	defer delete(alt_source_line2)

	alt_source_line3 := fmt.aprintf("source $HOME/.config/wayu/init.zsh")
	defer delete(alt_source_line3)

	if strings.contains(content, source_line) ||
	   strings.contains(content, alt_source_line) ||
	   strings.contains(content, alt_source_line2) ||
	   strings.contains(content, alt_source_line3) {
		fmt.println("\n✓ Wayu is already initialized in ~/.zshrc")
		return
	}

	// Ask user if they want to update .zshrc
	fmt.println("\nWayu setup is complete!")
	fmt.println("Would you like to add wayu to your ~/.zshrc? [Y/n]: ")

	// Read single character response
	input_buf: [10]byte
	n, err := os.read(os.stdin, input_buf[:])
	if err != nil {
		fmt.println("\nTo manually initialize wayu, add this line to your ~/.zshrc:")
		fmt.printfln("  source %s", init_file)
		return
	}

	response := strings.trim_space(string(input_buf[:n]))

	if response == "" || response == "y" || response == "Y" || response == "yes" || response == "Yes" {
		// Append to .zshrc
		new_content := fmt.aprintf("%s\n# Wayu shell configuration\nsource \"%s\"\n", content, init_file)
		defer delete(new_content)

		write_ok := os.write_entire_file(zshrc_path, transmute([]byte)new_content)
		if !write_ok {
			fmt.eprintfln("Error: Failed to write to %s", zshrc_path)
			fmt.println("Please manually add the following to your ~/.zshrc:")
			fmt.printfln("  source %s", init_file)
			return
		}

		fmt.println("✓ Successfully added wayu to ~/.zshrc")
		fmt.println("Run 'source ~/.zshrc' or restart your shell to apply changes")
	} else {
		fmt.println("\nTo manually initialize wayu, add this line to your ~/.zshrc:")
		fmt.printfln("  source %s", init_file)
	}
}

handle_init_command :: proc() {
	config_dir := fmt.aprintf("%s", WAYU_CONFIG)
	defer delete(config_dir)

	// Create main config directory
	if !os.exists(config_dir) {
		err := os.make_directory(config_dir)
		if err != nil {
			fmt.eprintfln("Error creating config directory: %v", err)
			os.exit(1)
		}
		fmt.printfln("Created directory: %s", config_dir)
	} else {
		fmt.printfln("Directory already exists: %s", config_dir)
	}

	// Create subdirectories
	subdirs := []string{"functions", "completions", "plugins"}
	for subdir in subdirs {
		subdir_path := fmt.aprintf("%s/%s", WAYU_CONFIG, subdir)
		defer delete(subdir_path)

		if !os.exists(subdir_path) {
			err := os.make_directory(subdir_path)
			if err != nil {
				fmt.eprintfln("Error creating directory %s: %v", subdir, err)
				os.exit(1)
			}
			fmt.printfln("Created directory: %s", subdir_path)
		} else {
			fmt.printfln("Directory already exists: %s", subdir_path)
		}
	}

	// Initialize config files
	path_file := fmt.aprintf("%s/%s", WAYU_CONFIG, PATH_FILE)
	defer delete(path_file)

	alias_file := fmt.aprintf("%s/%s", WAYU_CONFIG, ALIAS_FILE)
	defer delete(alias_file)

	constants_file := fmt.aprintf("%s/%s", WAYU_CONFIG, CONSTANTS_FILE)
	defer delete(constants_file)

	init_file := fmt.aprintf("%s/init.zsh", WAYU_CONFIG)
	defer delete(init_file)

	tools_file := fmt.aprintf("%s/tools.zsh", WAYU_CONFIG)
	defer delete(tools_file)

	created_files := 0

	if !os.exists(path_file) {
		if init_config_file(path_file, PATH_TEMPLATE) {
			fmt.printfln("Created config file: %s", path_file)
			created_files += 1
		}
	} else {
		fmt.printfln("Config file already exists: %s", path_file)
	}

	if !os.exists(alias_file) {
		if init_config_file(alias_file, ALIASES_TEMPLATE) {
			fmt.printfln("Created config file: %s", alias_file)
			created_files += 1
		}
	} else {
		fmt.printfln("Config file already exists: %s", alias_file)
	}

	if !os.exists(constants_file) {
		if init_config_file(constants_file, CONSTANTS_TEMPLATE) {
			fmt.printfln("Created config file: %s", constants_file)
			created_files += 1
		}
	} else {
		fmt.printfln("Config file already exists: %s", constants_file)
	}

	if !os.exists(init_file) {
		if init_config_file(init_file, INIT_TEMPLATE) {
			fmt.printfln("Created config file: %s", init_file)
			created_files += 1
		}
	} else {
		fmt.printfln("Config file already exists: %s", init_file)
	}

	if !os.exists(tools_file) {
		if init_config_file(tools_file, TOOLS_TEMPLATE) {
			fmt.printfln("Created config file: %s", tools_file)
			created_files += 1
		}
	} else {
		fmt.printfln("Config file already exists: %s", tools_file)
	}

	// Update .zshrc if needed
	update_zshrc(init_file)
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
	print_item("", "completions", "Manage Zsh completion scripts", EMOJI_COMMAND)
	print_item("", "init", "Initialize wayu configuration directory", EMOJI_INFO)
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
	fmt.printf("  wayu completions add jj /path/to/_jj\n")
	fmt.printf("  wayu completions rm              # Interactive removal\n")
	fmt.println()
}
