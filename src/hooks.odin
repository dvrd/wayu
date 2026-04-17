// hooks.odin - Pre/post action hooks for wayu
//
// Allows users to run custom commands before or after wayu operations.
// Useful for logging, notifications, or custom integrations.

package wayu

import "core:fmt"
import "core:os"
import "core:strings"

// Hook types
HookType :: enum {
	PRE_PATH_ADD,
	POST_PATH_ADD,
	PRE_PATH_REMOVE,
	POST_PATH_REMOVE,
	PRE_ALIAS_ADD,
	POST_ALIAS_ADD,
	PRE_ALIAS_REMOVE,
	POST_ALIAS_REMOVE,
	PRE_CONSTANT_ADD,
	POST_CONSTANT_ADD,
	PRE_CONSTANT_REMOVE,
	POST_CONSTANT_REMOVE,
	PRE_EXPORT,
	POST_EXPORT,
	PRE_PLUGIN_INSTALL,
	POST_PLUGIN_INSTALL,
}

// Hook configuration
HookConfig :: struct {
	pre_path_add:       string,
	post_path_add:      string,
	pre_path_remove:    string,
	post_path_remove:   string,
	pre_alias_add:      string,
	post_alias_add:     string,
	pre_alias_remove:   string,
	post_alias_remove:  string,
	pre_constant_add:   string,
	post_constant_add:  string,
	pre_constant_remove: string,
	post_constant_remove: string,
	pre_plugin_install: string,
	post_plugin_install: string,
	pre_export:         string,
	post_export:        string,
}

// Hook file path
HOOK_CONFIG_FILE :: "hooks.conf"

// Execute a hook if configured
execute_hook :: proc(hook_type: HookType, context_data: string = "") {
	hook_cmd := get_hook_command(hook_type)
	if len(hook_cmd) == 0 {
		return
	}

	// Replace placeholders
	cmd, _ := strings.replace_all(hook_cmd, "{path}", context_data, context.temp_allocator)
	cmd, _ = strings.replace_all(cmd, "{name}", context_data, context.temp_allocator)
	cmd, _ = strings.replace_all(cmd, "{value}", context_data, context.temp_allocator)

	// Execute via shell (fire and forget - don't block on output)
	debug("Executing hook: %s", cmd)
	hook_args := []string{"sh", "-c", cmd}
	run_command(hook_args)  // Ignoring return value - hooks are best-effort
}

// Get hook command for a type
get_hook_command :: proc(hook_type: HookType) -> string {
	config := load_hook_config()
	defer free_hook_config(config)

	result := ""
	switch hook_type {
	case .PRE_PATH_ADD:
		result = config.pre_path_add
	case .POST_PATH_ADD:
		result = config.post_path_add
	case .PRE_PATH_REMOVE:
		result = config.pre_path_remove
	case .POST_PATH_REMOVE:
		result = config.post_path_remove
	case .PRE_ALIAS_ADD:
		result = config.pre_alias_add
	case .POST_ALIAS_ADD:
		result = config.post_alias_add
	case .PRE_ALIAS_REMOVE:
		result = config.pre_alias_remove
	case .POST_ALIAS_REMOVE:
		result = config.post_alias_remove
	case .PRE_CONSTANT_ADD:
		result = config.pre_constant_add
	case .POST_CONSTANT_ADD:
		result = config.post_constant_add
	case .PRE_CONSTANT_REMOVE:
		result = config.pre_constant_remove
	case .POST_CONSTANT_REMOVE:
		result = config.post_constant_remove
	case .PRE_EXPORT:
		result = config.pre_export
	case .POST_EXPORT:
		result = config.post_export
	case .PRE_PLUGIN_INSTALL:
		result = config.pre_plugin_install
	case .POST_PLUGIN_INSTALL:
		result = config.post_plugin_install
	}

	// Clone the result before freeing config, so the caller gets a valid string
	cloned := strings.clone(result)
	return cloned
}

// Load hook configuration
load_hook_config :: proc() -> HookConfig {
	config: HookConfig

	hook_path := fmt.aprintf("%s/%s", WAYU_CONFIG, HOOK_CONFIG_FILE)
	defer delete(hook_path)

	if !os.exists(hook_path) {
		return config
	}

	content, ok := safe_read_file(hook_path)
	if !ok {
		return config
	}
	defer delete(content)

	// Simple parsing: one hook per line
	lines := strings.split(string(content), "\n")
	defer delete(lines)

	for &line in lines {
		line = strings.trim_space(line)
		if len(line) == 0 || strings.has_prefix(line, "#") {
			continue
		}

		parts := strings.split_n(line, "=", 2, context.temp_allocator)

		if len(parts) != 2 {
			continue
		}

		key := strings.trim_space(parts[0])
		value := strings.trim_space(parts[1])
		value = strings.trim(value, "\"") // Remove quotes if present

		switch key {
		case "pre_path_add":
			config.pre_path_add = strings.clone(value)
		case "post_path_add":
			config.post_path_add = strings.clone(value)
		case "pre_path_remove":
			config.pre_path_remove = strings.clone(value)
		case "post_path_remove":
			config.post_path_remove = strings.clone(value)
		case "pre_alias_add":
			config.pre_alias_add = strings.clone(value)
		case "post_alias_add":
			config.post_alias_add = strings.clone(value)
		case "pre_alias_remove":
			config.pre_alias_remove = strings.clone(value)
		case "post_alias_remove":
			config.post_alias_remove = strings.clone(value)
		case "pre_constant_add":
			config.pre_constant_add = strings.clone(value)
		case "post_constant_add":
			config.post_constant_add = strings.clone(value)
		case "pre_constant_remove":
			config.pre_constant_remove = strings.clone(value)
		case "post_constant_remove":
			config.post_constant_remove = strings.clone(value)
		case "pre_plugin_install":
			config.pre_plugin_install = strings.clone(value)
		case "post_plugin_install":
			config.post_plugin_install = strings.clone(value)
		case "pre_export":
			config.pre_export = strings.clone(value)
		case "post_export":
			config.post_export = strings.clone(value)
		}
	}

	return config
}

// Free hook config
free_hook_config :: proc(config: HookConfig) {
	delete(config.pre_path_add)
	delete(config.post_path_add)
	delete(config.pre_path_remove)
	delete(config.post_path_remove)
	delete(config.pre_alias_add)
	delete(config.post_alias_add)
	delete(config.pre_alias_remove)
	delete(config.post_alias_remove)
	delete(config.pre_constant_add)
	delete(config.post_constant_add)
	delete(config.pre_constant_remove)
	delete(config.post_constant_remove)
	delete(config.pre_plugin_install)
	delete(config.post_plugin_install)
	delete(config.pre_export)
	delete(config.post_export)
}

// Handle hooks command
handle_hooks_command :: proc(action: Action, args: []string) {
	#partial switch action {
	case .LIST:
		show_hooks_status()
	case .ADD:
		edit_hooks_config()
	case .HELP:
		print_hooks_usage()
	case:
		show_hooks_status()
	}
}

// Show current hooks status
show_hooks_status :: proc() {
	print_header("Configured Hooks", "🪝")
	fmt.println()

	config := load_hook_config()
	defer free_hook_config(config)

	has_hooks := false

	check_and_print :: proc(name: string, cmd: string, has_hooks: ^bool) {
		if len(cmd) > 0 {
			fmt.printfln("  %s%s%s: %s", get_primary(), name, RESET, cmd)
			has_hooks^ = true
		}
	}

	check_and_print("pre_path_add", config.pre_path_add, &has_hooks)
	check_and_print("post_path_add", config.post_path_add, &has_hooks)
	check_and_print("pre_path_remove", config.pre_path_remove, &has_hooks)
	check_and_print("post_path_remove", config.post_path_remove, &has_hooks)
	check_and_print("pre_alias_add", config.pre_alias_add, &has_hooks)
	check_and_print("post_alias_add", config.post_alias_add, &has_hooks)
	check_and_print("pre_plugin_install", config.pre_plugin_install, &has_hooks)
	check_and_print("post_plugin_install", config.post_plugin_install, &has_hooks)
	check_and_print("pre_export", config.pre_export, &has_hooks)
	check_and_print("post_export", config.post_export, &has_hooks)

	if !has_hooks {
		fmt.printfln("  %sNo hooks configured%s", get_muted(), RESET)
		fmt.println()
		fmt.println("Hooks let you run custom commands before/after wayu operations.")
		fmt.println()
		fmt.printfln("Edit %s/%s to configure hooks.", WAYU_CONFIG, HOOK_CONFIG_FILE)
	}

	fmt.println()
	fmt.printfln("%sAvailable placeholders:%s", get_secondary(), RESET)
	fmt.println("  {path}   - The PATH entry being added/removed")
	fmt.println("  {name}   - The alias/constant name")
	fmt.println("  {value}  - The alias command or constant value")
}

// Edit hooks configuration
edit_hooks_config :: proc() {
	hook_path := fmt.aprintf("%s/%s", WAYU_CONFIG, HOOK_CONFIG_FILE)
	defer delete(hook_path)

	if !os.exists(hook_path) {
		// Create example hooks file
		example := `# wayu hooks configuration
# Uncomment and modify lines to enable hooks

# Path hooks
# pre_path_add = "echo 'Adding {path}' >> ~/wayu.log"
# post_path_add = "hash -r"

# Alias hooks  
# pre_alias_add = "echo 'New alias: {name}'"
# post_alias_add = "source ~/.zshrc"

# Plugin hooks
# post_plugin_install = "echo 'Installed {name}' >> ~/plugins.log"

# Export hooks
# pre_export = "echo 'Generating turbo export...'"
# post_export = "echo 'Export complete'"
`
		write_ok := safe_write_file(hook_path, transmute([]byte)(example))
		if !write_ok {
			print_error("Failed to create hooks config")
			os.exit(EXIT_IOERR)
		}
	}

	// Open in editor
	editor := os.get_env_alloc("EDITOR", context.temp_allocator)
	if len(editor) == 0 {
		editor = "vi"
	}

	print_info("Opening hooks config in %s...", editor)
	editor_args := []string{editor, hook_path}
	ok := run_command_with_stdin(editor_args, "")
	if !ok {
		print_error("Failed to open editor: %s", editor)
		os.exit(EXIT_IOERR)
	}
}

// Print hooks usage
print_hooks_usage :: proc() {
	fmt.println()
	fmt.printfln("%swayu hooks - Pre/post action hooks%s", BOLD, RESET)
	fmt.println()
	fmt.printfln("%sUSAGE:%s", get_primary(), RESET)
	fmt.printfln("  wayu hooks              Show configured hooks")
	fmt.printfln("  wayu hooks run          Execute configured hooks")
	fmt.printfln("  wayu hooks edit         Edit hooks configuration")
	fmt.printfln("  wayu hooks help         Show this help")
	fmt.println()
	fmt.printfln("%sDESCRIPTION:%s", get_primary(), RESET)
	fmt.println("  Hooks allow running custom commands before/after wayu operations.")
	fmt.println("  Useful for logging, notifications, or custom integrations.")
	fmt.println()
	fmt.printfln("%sCONFIG FILE:%s", get_primary(), RESET)
	fmt.printfln("  ~/.config/wayu/hooks.conf", WAYU_CONFIG)
	fmt.println()
	fmt.printfln("%sEXAMPLE HOOKS:%s", get_primary(), RESET)
	fmt.println()
	fmt.println("  # Log PATH changes")
	fmt.println(`  pre_path_add = "echo 'Adding {path}' >> ~/wayu.log"`)
	fmt.println()
	fmt.println("  # Reload shell after alias changes")
	fmt.println(`  post_alias_add = "source ~/.zshrc"`)
	fmt.println()
	fmt.println("  # Notify when plugins are installed")
	fmt.println(`  post_plugin_install = "terminal-notifier -title 'wayu' -message 'Installed {name}'"`)
}

// Integration with existing commands - call hooks
// These should be called from the actual add/remove functions

hook_pre_path_add :: proc(path: string) {
	execute_hook(.PRE_PATH_ADD, path)
}

hook_post_path_add :: proc(path: string) {
	execute_hook(.POST_PATH_ADD, path)
}

hook_pre_path_remove :: proc(path: string) {
	execute_hook(.PRE_PATH_REMOVE, path)
}

hook_post_path_remove :: proc(path: string) {
	execute_hook(.POST_PATH_REMOVE, path)
}

hook_pre_export :: proc() {
	execute_hook(.PRE_EXPORT)
}

hook_post_export :: proc() {
	execute_hook(.POST_EXPORT)
}

hook_pre_alias_add :: proc(name: string) {
	execute_hook(.PRE_ALIAS_ADD, name)
}

hook_post_alias_add :: proc(name: string) {
	execute_hook(.POST_ALIAS_ADD, name)
}

hook_pre_alias_remove :: proc(name: string) {
	execute_hook(.PRE_ALIAS_REMOVE, name)
}

hook_post_alias_remove :: proc(name: string) {
	execute_hook(.POST_ALIAS_REMOVE, name)
}

hook_pre_constant_add :: proc(name: string) {
	execute_hook(.PRE_CONSTANT_ADD, name)
}

hook_post_constant_add :: proc(name: string) {
	execute_hook(.POST_CONSTANT_ADD, name)
}

hook_pre_constant_remove :: proc(name: string) {
	execute_hook(.PRE_CONSTANT_REMOVE, name)
}

hook_post_constant_remove :: proc(name: string) {
	execute_hook(.POST_CONSTANT_REMOVE, name)
}

hook_pre_plugin_install :: proc(name: string) {
	execute_hook(.PRE_PLUGIN_INSTALL, name)
}

hook_post_plugin_install :: proc(name: string) {
	execute_hook(.POST_PLUGIN_INSTALL, name)
}
