// theme.odin - Theme management system for wayu
//
// This module provides theme management functionality including:
// - wayu theme list - List available themes
// - wayu theme add <name> - Add a built-in theme
// - wayu theme remove <name> - Remove a custom theme
// - wayu theme enable <name> - Enable a theme
// - wayu theme get-active - Show the current active theme

package wayu

import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode"
import "core:path/filepath"

// Theme command actions
ThemeAction :: enum {
	LIST,
	ADD,
	REMOVE,
	ENABLE,
	GET_ACTIVE,
	HELP,
	UNKNOWN,
}

// Built-in theme names
BUILT_IN_THEMES :: []string{"minimal", "powerline", "default"}

// Theme file paths
THEME_DIR : string
ACTIVE_THEME_FILE : string

// Initialize theme globals
init_theme_globals :: proc() {
	if _GLOBALS_INITIALIZED {
		THEME_DIR = fmt.aprintf("%s/themes", WAYU_CONFIG)
		ACTIVE_THEME_FILE = fmt.aprintf("%s/active_theme.txt", WAYU_CONFIG)
	}
}

// ============================================================================
// Public API
// ============================================================================

// theme_list :: proc() -> []ThemeConfig
// Returns a list of all available themes (built-in + custom)
theme_list :: proc() -> []ThemeConfig {
	themes := make([dynamic]ThemeConfig)

	// Add built-in themes
	for theme_name in BUILT_IN_THEMES {
		theme := ThemeConfig{
			name = theme_name,
			type = theme_type_from_name(theme_name),
			starship_config = "",
			custom_prompt = "",
			colors = make(map[string]string),
		}
		append(&themes, theme)
	}

	// Add custom themes from filesystem
	if os.exists(THEME_DIR) {
		fd, err := os.open(THEME_DIR)
		if err == nil {
			defer os.close(fd)

			entries, read_err := os.read_dir(fd, -1)
			if read_err == nil {
				defer delete(entries)

				for entry in entries {
					if entry.is_dir {
						continue
					}

					name := entry.name
					if !strings.has_suffix(name, ".toml") {
						continue
					}

					// Extract theme name from filename
					theme_name := strings.trim_suffix(name, ".toml")

					// Skip if it's a built-in theme (already added)
					if is_built_in_theme(theme_name) {
						continue
					}

					// Load custom theme
					theme_path := fmt.aprintf("%s/%s", THEME_DIR, name)
					defer delete(theme_path)

					theme, ok := load_theme_from_file(theme_path)
					if ok {
						append(&themes, theme)
					}
				}
			}
		}
	}

	return themes[:]
}

// theme_apply :: proc(name: string) -> bool
// Applies a theme by name (built-in or custom)
theme_apply :: proc(name: string) -> bool {
	// Special handling for starship
	if name == "starship" {
		return theme_starship_apply()
	}

	// Check if it's a built-in theme
	if is_built_in_theme(name) {
		// Copy built-in theme file to active theme
		theme_content := get_built_in_theme_content(name)
		if len(theme_content) == 0 {
			print_error("Built-in theme '%s' not found", name)
			return false
		}

		// Ensure themes directory exists
		ensure_theme_dir()

		// Write active theme
		return write_active_theme(name, theme_content)
	}

	// Check for custom theme
	theme_path := fmt.aprintf("%s/%s.toml", THEME_DIR, name)
	defer delete(theme_path)

	if !os.exists(theme_path) {
		print_error("Theme '%s' not found", name)
		return false
	}

	content, ok := safe_read_file(theme_path)
	if !ok {
		print_error("Failed to read theme file: %s", theme_path)
		return false
	}
	defer delete(content)

	return write_active_theme(name, string(content))
}

// theme_exists :: proc(name: string) -> bool
// Checks if a theme exists (built-in or custom)
theme_exists :: proc(name: string) -> bool {
	if is_built_in_theme(name) {
		return true
	}

	theme_path := fmt.aprintf("%s/%s.toml", THEME_DIR, name)
	defer delete(theme_path)

	return os.exists(theme_path)
}

// theme_starship_detect :: proc() -> bool
// Detects if Starship is installed
theme_starship_detect :: proc() -> bool {
	return theme_detect_starship()
}

// ============================================================================
// Command Handlers
// ============================================================================

// Main handler for theme commands
handle_theme_command :: proc(action: ThemeAction, args: []string) {
	// Initialize theme globals if not already done
	init_theme_globals()
	ensure_theme_dir()

	#partial switch action {
	case .LIST:
		theme_list_command()
	case .ADD:
		if len(args) == 0 {
			print_error("Missing theme name")
			fmt.println()
			fmt.printfln("Usage: wayu theme add <minimal|powerline|default|custom-name>")
			fmt.println()
			fmt.printfln("Examples:")
			fmt.printfln("  wayu theme add minimal")
			fmt.printfln("  wayu theme add my-custom-theme")
			os.exit(EXIT_USAGE)
		}
		theme_add_command(args[0])
	case .REMOVE:
		if len(args) == 0 {
			print_error("Missing theme name")
			fmt.println()
			fmt.printfln("Usage: wayu theme remove <name>")
			os.exit(EXIT_USAGE)
		}
		theme_remove_command(args[0])
	case .ENABLE:
		if len(args) == 0 {
			print_error("Missing theme name")
			fmt.println()
			fmt.printfln("Usage: wayu theme enable <name>")
			fmt.println()
			fmt.printfln("Available themes:")
			theme_list_command()
			os.exit(EXIT_USAGE)
		}
		theme_enable_command(args[0])
	case .GET_ACTIVE:
		theme_get_active_command()
	case .HELP:
		print_theme_help()
	case .UNKNOWN:
		print_error("Unknown theme action")
		print_theme_help()
		os.exit(EXIT_USAGE)
	}
}

// theme_list_command - List all available themes
theme_list_command :: proc() {
	themes := theme_list()
	defer {
		for theme in themes {
			delete(theme.colors)
		}
		delete(themes)
	}

	active_theme := get_active_theme_name()
	defer delete(active_theme)

	print_header("Available Themes", "🎨")
	fmt.println()

	if len(themes) == 0 {
		fmt.printfln("No themes found.")
		fmt.println()
		fmt.printfln("Add a theme with:")
		fmt.printfln("  wayu theme add <minimal|powerline|default>")
		return
	}

	// Table header
	fmt.printfln("  %-20s %-15s %-10s", "NAME", "TYPE", "STATUS")
	fmt.printfln("  %s", strings.repeat("-", 50))

	for theme in themes {
		status := ""
		if theme.name == active_theme {
			status = fmt.aprintf("%s[active]%s", get_success(), RESET)
		}

		type_str := theme_type_to_string(theme.type)

		icon := "  "
		if is_built_in_theme(theme.name) {
			icon = "📦 "
		} else {
			icon = "🔧 "
		}

		fmt.printfln("  %-20s %-15s %-10s", theme.name, type_str, status)
		if theme.name == active_theme {
			delete(status)
		}
	}

	fmt.println()
	fmt.printfln("%sLegend:%s 📦 Built-in  🔧 Custom  %s[active]%s Enabled",
		get_muted(), RESET, get_success(), RESET)
}

// theme_add_command - Add a theme (built-in or custom)
theme_add_command :: proc(name: string) {
	// Validate theme name
	validation := validate_theme_name(name)
	if !validation.valid {
		print_error("%s", validation.error_message)
		delete(validation.error_message)
		os.exit(EXIT_DATAERR)
	}
	if len(validation.warning) > 0 {
		print_warning("%s", validation.warning)
		delete(validation.warning)
	}

	// Check if theme already exists
	if theme_exists(name) {
		print_warning("Theme '%s' already exists", name)
		return
	}

	// If it's a built-in theme, copy it
	if is_built_in_theme(name) {
		// Create themes directory if needed
		if !ensure_theme_dir() {
			print_error("Failed to create themes directory")
			os.exit(EXIT_CANTCREAT)
		}

		// Copy built-in theme to user themes directory
		theme_content := get_built_in_theme_content(name)
		if len(theme_content) == 0 {
			print_error("Built-in theme '%s' not found", name)
			os.exit(EXIT_CONFIG)
		}

		dest_path := fmt.aprintf("%s/%s.toml", THEME_DIR, name)
		defer delete(dest_path)

		if !safe_write_file(dest_path, transmute([]byte)theme_content) {
			print_error("Failed to write theme file: %s", dest_path)
			os.exit(EXIT_IOERR)
		}

		print_success("Added built-in theme: %s", name)
		return
	}

	// Create a new custom theme template
	if !ensure_theme_dir() {
		print_error("Failed to create themes directory")
		os.exit(EXIT_CANTCREAT)
	}

	theme_path := fmt.aprintf("%s/%s.toml", THEME_DIR, name)
	defer delete(theme_path)

	template := generate_custom_theme_template(name)
	defer delete(template)

	if !safe_write_file(theme_path, transmute([]byte)template) {
		print_error("Failed to write theme file: %s", theme_path)
		os.exit(EXIT_IOERR)
	}

	print_success("Created custom theme: %s", name)
	fmt.println()
	fmt.printfln("Edit %s%s%s to customize your theme", get_secondary(), theme_path, RESET)
}

// theme_remove_command - Remove a custom theme
theme_remove_command :: proc(name: string) {
	// Cannot remove built-in themes
	if is_built_in_theme(name) {
		// Check if it's been copied to user directory
		theme_path := fmt.aprintf("%s/%s.toml", THEME_DIR, name)
		defer delete(theme_path)

		if !os.exists(theme_path) {
			print_error("Cannot remove built-in theme '%s'", name)
			fmt.println()
			fmt.printfln("Built-in themes are part of wayu and cannot be removed.")
			os.exit(EXIT_DATAERR)
		}

		// It's a copy, allow removal
		if !YES_FLAG {
			print_error("This operation requires confirmation.")
			fmt.println()
			fmt.printfln("Will remove theme: %s", name)
			fmt.println()
			fmt.printfln("Add --yes flag to proceed:")
			fmt.printfln("  wayu theme remove %s --yes", name)
			os.exit(EXIT_GENERAL)
		}

		// Check if it's the active theme
		active_theme := get_active_theme_name()
		defer delete(active_theme)

		if name == active_theme {
			// Remove active theme marker
			if os.exists(ACTIVE_THEME_FILE) {
				os.remove(ACTIVE_THEME_FILE)
			}
		}

		if err := os.remove(theme_path); err != nil {
			print_error("Failed to remove theme file: %v", err)
			os.exit(EXIT_IOERR)
		}

		print_success("Removed theme: %s", name)
		return
	}

	// Remove custom theme
	theme_path := fmt.aprintf("%s/%s.toml", THEME_DIR, name)
	defer delete(theme_path)

	if !os.exists(theme_path) {
		print_error("Theme '%s' not found", name)
		os.exit(EXIT_NOINPUT)
	}

	if !YES_FLAG {
		print_error("This operation requires confirmation.")
		fmt.println()
		fmt.printfln("Will remove theme: %s", name)
		fmt.println()
		fmt.printfln("Add --yes flag to proceed:")
		fmt.printfln("  wayu theme remove %s --yes", name)
		os.exit(EXIT_GENERAL)
	}

	// Check if it's the active theme
	active_theme := get_active_theme_name()
	defer delete(active_theme)

	if name == active_theme {
		// Remove active theme marker
		if os.exists(ACTIVE_THEME_FILE) {
			os.remove(ACTIVE_THEME_FILE)
		}
	}

	if err := os.remove(theme_path); err != nil {
		print_error("Failed to remove theme file: %v", err)
		os.exit(EXIT_IOERR)
	}

	print_success("Removed theme: %s", name)
}

// theme_enable_command - Enable a theme
theme_enable_command :: proc(name: string) {
	// Special handling for starship
	if name == "starship" {
		if !theme_detect_starship() {
			print_error("Starship is not installed")
			fmt.println()
			fmt.printfln("Install Starship with:")
			fmt.printfln("  curl -sS https://starship.rs/install.sh | sh")
			fmt.println()
			fmt.printfln("Or use a built-in theme:")
			fmt.printfln("  wayu theme enable minimal")
			os.exit(EXIT_UNAVAILABLE)
		}

		if theme_starship_apply() {
			print_success("Starship theme enabled")
			fmt.println()
			fmt.printfln("Restart your shell or run 'source %s' to apply changes", get_rc_file_path(DETECTED_SHELL))
		} else {
			print_error("Failed to enable Starship theme")
			os.exit(EXIT_SOFTWARE)
		}
		return
	}

	// Check if theme exists
	if !theme_exists(name) {
		print_error("Theme '%s' not found", name)
		fmt.println()
		fmt.printfln("Available themes:")
		theme_list_command()
		os.exit(EXIT_NOINPUT)
	}

	if theme_apply(name) {
		print_success("Theme enabled: %s", name)
		fmt.println()
		fmt.printfln("Restart your shell or run 'source %s' to apply changes", get_rc_file_path(DETECTED_SHELL))
	} else {
		print_error("Failed to enable theme: %s", name)
		os.exit(EXIT_SOFTWARE)
	}
}

// theme_get_active_command - Show the currently active theme
theme_get_active_command :: proc() {
	active_theme := get_active_theme_name()
	defer delete(active_theme)

	if len(active_theme) == 0 {
		fmt.printfln("No theme currently active")
		fmt.println()
		fmt.printfln("Enable a theme with:")
		fmt.printfln("  wayu theme enable <name>")
		return
	}

	fmt.printfln("Active theme: %s%s%s", get_primary(), active_theme, RESET)

	// Show theme details
	theme, ok := get_active_theme_config()
	if ok {
		defer delete(theme.colors)
		fmt.printfln("Type: %s", theme_type_to_string(theme.type))

		if theme.type == .Starship {
			starship_path := os.expand_env("${HOME}/.config/starship.toml")
			defer delete(starship_path)
			fmt.printfln("Config: %s", starship_path)
		}
	}
}

// ============================================================================
// Helper Functions
// ============================================================================

// Ensure the themes directory exists
ensure_theme_dir :: proc() -> bool {
	if os.exists(THEME_DIR) {
		return true
	}

	err := os.make_directory(THEME_DIR)
	return err == nil
}

// Get the active theme name
get_active_theme_name :: proc() -> string {
	if !os.exists(ACTIVE_THEME_FILE) {
		return ""
	}

	content, ok := safe_read_file(ACTIVE_THEME_FILE)
	if !ok {
		return ""
	}
	defer delete(content)

	return strings.trim_space(string(content))
}

// Write active theme
write_active_theme :: proc(name: string, content: string) -> bool {
	// Write to active_theme.txt
	name_bytes := transmute([]byte)name
	if !safe_write_file(ACTIVE_THEME_FILE, name_bytes) {
		return false
	}

	// Apply theme to shell config
	return apply_theme_to_shell(name, content)
}

// Apply theme settings to the shell configuration
apply_theme_to_shell :: proc(name: string, content: string) -> bool {
	// Read the init file
	init_file := fmt.aprintf("%s/%s", WAYU_CONFIG, INIT_FILE)
	defer delete(init_file)

	if !os.exists(init_file) {
		print_error("Wayu not initialized. Run 'wayu init' first.")
		return false
	}

	file_content, ok := safe_read_file(init_file)
	if !ok {
		return false
	}
	defer delete(file_content)

	content_str := string(file_content)
	lines := strings.split(content_str, "\n")
	defer delete(lines)

	// Find and update theme configuration
	new_lines := make([dynamic]string)
	defer {
		for line in new_lines {
			delete(line)
		}
		delete(new_lines)
	}

	found_theme_section := false
	in_theme_section := false

	for line in lines {
		trimmed := strings.trim_space(line)

		// Check for theme section markers
		if strings.contains(line, "# WAYU THEME BEGIN") {
			found_theme_section = true
			in_theme_section = true
			append(&new_lines, strings.clone(line))
			continue
		}

		if strings.contains(line, "# WAYU THEME END") {
			in_theme_section = false
			append(&new_lines, strings.clone(line))
			continue
		}

		if in_theme_section {
			// Skip old theme config lines
			continue
		}

		append(&new_lines, strings.clone(line))
	}

	// If no theme section found, add one before the final export
	if !found_theme_section {
		// Add theme section
		insert_idx := len(new_lines)

		// Look for a good insertion point (before the PATH export)
		for i := len(new_lines) - 1; i >= 0; i -= 1 {
			if strings.contains(new_lines[i], "export PATH") {
				insert_idx = i
				break
			}
		}

		// Insert theme configuration
		theme_config := generate_theme_shell_config(name)
		defer delete(theme_config)

		// Split theme config and insert
		theme_lines := strings.split(theme_config, "\n")
		defer delete(theme_lines)

		for theme_line in theme_lines {
			inject_at(&new_lines, insert_idx, strings.clone(theme_line))
			insert_idx += 1
		}
	} else {
		// Re-add theme section with new config
		// Find the BEGIN marker and insert after it
		for i := 0; i < len(new_lines); i += 1 {
			if strings.contains(new_lines[i], "# WAYU THEME BEGIN") {
				theme_config := generate_theme_shell_config(name)
				defer delete(theme_config)

				theme_lines := strings.split(theme_config, "\n")
				defer delete(theme_lines)

				// Insert after BEGIN (skip BEGIN line)
				for j := 0; j < len(theme_lines); j += 1 {
					if j == 0 && strings.contains(theme_lines[j], "BEGIN") {
						continue
					}
					if strings.contains(theme_lines[j], "END") {
						continue
					}
					inject_at(&new_lines, i + 1 + j, strings.clone(theme_lines[j]))
				}
				break
			}
		}
	}

	// Write updated content
	final_content := strings.join(new_lines[:], "\n")
	defer delete(final_content)

	if !safe_write_file(init_file, transmute([]byte)final_content) {
		return false
	}

	return true
}

// Generate shell configuration for a theme
generate_theme_shell_config :: proc(name: string) -> string {
	if name == "starship" {
		return generate_starship_shell_config()
	}

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	// Built-in themes
	switch name {
	case "minimal":
		fmt.sbprintln(&builder, "# WAYU THEME BEGIN - minimal")
		fmt.sbprintln(&builder, "# Minimal theme: Clean, simple prompt")
		fmt.sbprintln(&builder, "PS1='$ '" )
		fmt.sbprintln(&builder, "# WAYU THEME END")
	case "powerline":
		fmt.sbprintln(&builder, "# WAYU THEME BEGIN - powerline")
		fmt.sbprintln(&builder, "# Powerline theme: Fancy prompt with segments")
		fmt.sbprintln(&builder, "# Note: Requires powerline fonts")
		fmt.sbprintln(&builder, "PS1='%F{cyan}%~%f %F{green}❯%f '")
		fmt.sbprintln(&builder, "# WAYU THEME END")
	case "default":
		fmt.sbprintln(&builder, "# WAYU THEME BEGIN - default")
		fmt.sbprintln(&builder, "# Default theme: Wayu's standard prompt")
		fmt.sbprintln(&builder, "PS1='%F{blue}%n%f@%F{green}%m%f:%F{yellow}%~%f$ '")
		fmt.sbprintln(&builder, "# WAYU THEME END")
	case:
		// Custom theme - load from file
		theme_path := fmt.aprintf("%s/%s.toml", THEME_DIR, name)
		defer delete(theme_path)

		if os.exists(theme_path) {
			content, ok := safe_read_file(theme_path)
			if ok {
				defer delete(content)
				// Parse TOML and generate shell config
				return generate_custom_theme_shell_config(string(content), name)
			}
		}

		// Fallback
		fmt.sbprintln(&builder, "# WAYU THEME BEGIN - custom")
		fmt.sbprintf(&builder, "# Custom theme: %s\n", name)
		fmt.sbprintln(&builder, "PS1='$ '")
		fmt.sbprintln(&builder, "# WAYU THEME END")
	}

	return strings.clone(strings.to_string(builder))
}

// Generate shell config for a custom theme from TOML
generate_custom_theme_shell_config :: proc(toml_content: string, name: string) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	fmt.sbprintln(&builder, "# WAYU THEME BEGIN - custom")
	fmt.sbprintf(&builder, "# Custom theme: %s\n", name)

	// Parse simple TOML (name, type, colors)
	lines := strings.split(toml_content, "\n")
	defer delete(lines)

	colors := make(map[string]string)
	defer delete(colors)

	in_colors_section := false

	for line in lines {
		trimmed := strings.trim_space(line)

		if strings.has_prefix(trimmed, "[colors]") {
			in_colors_section = true
			continue
		}

		if strings.has_prefix(trimmed, "[") && trimmed != "[colors]" {
			in_colors_section = false
			continue
		}

		if in_colors_section && strings.contains(trimmed, "=") {
			parts := strings.split(trimmed, "=")
			defer delete(parts)

			if len(parts) >= 2 {
				key := strings.trim_space(parts[0])
				value := strings.trim_space(parts[1])
				// Remove quotes
				value = strings.trim_prefix(value, "\"")
				value = strings.trim_suffix(value, "\"")
				colors[key] = value
			}
		}
	}

	// Generate PS1 based on type
	theme_type := "minimal"
	for line in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "type") && strings.contains(trimmed, "=") {
			parts := strings.split(trimmed, "=")
			if len(parts) >= 2 {
				theme_type = strings.trim_space(parts[1])
				theme_type = strings.trim_prefix(theme_type, "\"")
				theme_type = strings.trim_suffix(theme_type, "\"")
			}
		}
	}

	// Generate prompt based on colors
	primary_color := colors["primary"] if "primary" in colors else "cyan"
	secondary_color := colors["secondary"] if "secondary" in colors else "white"

	// Map color names to zsh color codes
	color_map := map[string]string{
		"black" = "%F{black}",
		"red" = "%F{red}",
		"green" = "%F{green}",
		"yellow" = "%F{yellow}",
		"blue" = "%F{blue}",
		"magenta" = "%F{magenta}",
		"cyan" = "%F{cyan}",
		"white" = "%F{white}",
	}
	defer delete(color_map)

	primary := color_map[primary_color] if primary_color in color_map else "%F{cyan}"
	secondary := color_map[secondary_color] if secondary_color in color_map else "%F{white}"

	switch theme_type {
	case "powerline":
		fmt.sbprintf(&builder, "PS1='%s%~%f %s❯%f '\n", primary, secondary)
	case "minimal":
		fmt.sbprintln(&builder, "PS1='$ '")
	case:
		fmt.sbprintf(&builder, "PS1='%s%n%f@%s%m%f:%s%~%f$ '\n", primary, secondary, primary)
	}

	fmt.sbprintln(&builder, "# WAYU THEME END")

	return strings.clone(strings.to_string(builder))
}

// Get active theme configuration
get_active_theme_config :: proc() -> (ThemeConfig, bool) {
	active_name := get_active_theme_name()
	defer delete(active_name)

	if len(active_name) == 0 {
		return ThemeConfig{}, false
	}

	if active_name == "starship" {
		return ThemeConfig{
			name = "starship",
			type = .Starship,
			starship_config = "~/.config/starship.toml",
			colors = make(map[string]string),
		}, true
	}

	// Load from file
	theme_path := fmt.aprintf("%s/%s.toml", THEME_DIR, active_name)
	defer delete(theme_path)

	if os.exists(theme_path) {
		return load_theme_from_file(theme_path)
	}

	// Return basic built-in theme config
	return ThemeConfig{
		name = active_name,
		type = theme_type_from_name(active_name),
		colors = make(map[string]string),
	}, true
}

// Load a theme from a TOML file
load_theme_from_file :: proc(path: string) -> (ThemeConfig, bool) {
	content, ok := safe_read_file(path)
	if !ok {
		return ThemeConfig{}, false
	}
	defer delete(content)

	content_str := string(content)
	lines := strings.split(content_str, "\n")
	defer delete(lines)

	theme := ThemeConfig{
		colors = make(map[string]string),
	}

	in_colors_section := false
	in_starship_section := false

	for line in lines {
		trimmed := strings.trim_space(line)

		// Skip comments and empty lines
		if len(trimmed) == 0 || strings.has_prefix(trimmed, "#") {
			continue
		}

		// Section headers
		if trimmed == "[colors]" {
			in_colors_section = true
			in_starship_section = false
			continue
		}
		if trimmed == "[starship]" {
			in_colors_section = false
			in_starship_section = true
			continue
		}

		// Parse key = value
		if !strings.contains(trimmed, "=") {
			continue
		}

		parts := strings.split(trimmed, "=")
		defer delete(parts)

		if len(parts) < 2 {
			continue
		}

		key := strings.trim_space(parts[0])
		value := strings.trim_space(parts[1])

		// Remove quotes
		value = strings.trim_prefix(value, "\"")
		value = strings.trim_suffix(value, "\"")

		if key == "name" && len(theme.name) == 0 {
			theme.name = strings.clone(value)
		} else if key == "type" {
			theme.type = theme_type_from_string(value)
		} else if in_colors_section {
			theme.colors[key] = strings.clone(value)
		} else if in_starship_section && key == "config_path" {
			theme.starship_config = strings.clone(value)
		}
	}

	// Infer name from filename if not specified
	if len(theme.name) == 0 {
		base := filepath.base(path)
		theme.name = strings.clone(strings.trim_suffix(base, ".toml"))
	}

	return theme, true
}

// ============================================================================
// Utility Functions
// ============================================================================

// Check if a theme name is a built-in theme
is_built_in_theme :: proc(name: string) -> bool {
	for built_in in BUILT_IN_THEMES {
		if name == built_in {
			return true
		}
	}
	return false
}

// Convert theme type to string
theme_type_to_string :: proc(t: ThemeType) -> string {
	switch t {
	case .Minimal:
		return "minimal"
	case .Powerline:
		return "powerline"
	case .Starship:
		return "starship"
	case .Custom:
		return "custom"
	}
	return "unknown"
}

// Convert string to theme type
theme_type_from_string :: proc(s: string) -> ThemeType {
	switch s {
	case "minimal":
		return .Minimal
	case "powerline":
		return .Powerline
	case "starship":
		return .Starship
	case "custom":
		return .Custom
	}
	return .Custom
}

// Get theme type from name
theme_type_from_name :: proc(name: string) -> ThemeType {
	switch name {
	case "minimal":
		return .Minimal
	case "powerline":
		return .Powerline
	case "starship":
		return .Starship
	}
	return .Custom
}

// Get built-in theme content
get_built_in_theme_content :: proc(name: string) -> string {
	switch name {
	case "minimal":
		return `name = "minimal"
type = "minimal"

[colors]
primary = "cyan"
secondary = "white"
error = "red"
success = "green"
`
	case "powerline":
		return `name = "powerline"
type = "powerline"

[colors]
primary = "cyan"
secondary = "green"
error = "red"
success = "green"
`
	case "default":
		return `name = "default"
type = "custom"

[colors]
primary = "blue"
secondary = "green"
error = "red"
success = "green"
`
	}
	return ""
}

// Generate template for a custom theme
generate_custom_theme_template :: proc(name: string) -> string {
	return fmt.aprintf(`name = "%s"
type = "custom"

[colors]
primary = "cyan"
secondary = "white"
error = "red"
success = "green"

# Available colors: black, red, green, yellow, blue, magenta, cyan, white
# Available types: minimal, powerline, custom
`, name)
}

// Validate theme name
validate_theme_name :: proc(name: string) -> ValidationResult {
	if len(name) == 0 {
		return ValidationResult{
			valid = false,
			error_message = strings.clone("Theme name cannot be empty"),
		}
	}

	// Check valid characters (alphanumeric, hyphens, underscores)
	for r in name {
		if !unicode.is_alpha(r) && !unicode.is_digit(r) && r != '-' && r != '_' {
			return ValidationResult{
				valid = false,
				error_message = fmt.aprintf("Theme name contains invalid character: '%c'", r),
			}
		}
	}

	// Check length
	if len(name) > 64 {
		return ValidationResult{
			valid = false,
			error_message = strings.clone("Theme name too long (max 64 characters)"),
		}
	}

	return ValidationResult{valid = true}
}

// Print theme help
print_theme_help :: proc() {
	print_header("Theme Management", "🎨")
	fmt.println()

	fmt.printfln("%sAvailable Commands:%s", get_primary(), RESET)
	fmt.println()
	fmt.printfln("  %swayu theme list%s              List all available themes", BOLD, RESET)
	fmt.printfln("  %swayu theme add <name>%s        Add a built-in or custom theme", BOLD, RESET)
	fmt.printfln("  %swayu theme remove <name>%s   Remove a custom theme", BOLD, RESET)
	fmt.printfln("  %swayu theme enable <name>%s    Enable a theme", BOLD, RESET)
	fmt.printfln("  %swayu theme get-active%s      Show currently active theme", BOLD, RESET)
	fmt.println()

	fmt.printfln("%sBuilt-in Themes:%s", get_primary(), RESET)
	fmt.println()
	fmt.printfln("  %sminimal%s    Clean, simple prompt", BOLD, RESET)
	fmt.printfln("  %spowerline%s  Fancy prompt with segments (requires powerline fonts)", BOLD, RESET)
	fmt.printfln("  %sdefault%s    Wayu's standard prompt", BOLD, RESET)
	fmt.println()

	fmt.printfln("%sExternal Integration:%s", get_primary(), RESET)
	fmt.println()
	fmt.printfln("  %sstarship%s   Cross-shell prompt (requires starship to be installed)", BOLD, RESET)
	fmt.println()

	fmt.printfln("%sExamples:%s", get_primary(), RESET)
	fmt.println()
	fmt.printfln("  wayu theme add minimal")
	fmt.printfln("  wayu theme enable starship")
	fmt.printfln("  wayu theme remove my-theme --yes")
}

// Parse theme action from string
parse_theme_action :: proc(s: string) -> ThemeAction {
	switch s {
	case "list", "ls":
		return .LIST
	case "add":
		return .ADD
	case "remove", "rm":
		return .REMOVE
	case "enable":
		return .ENABLE
	case "get-active", "active":
		return .GET_ACTIVE
	case "help", "-h", "--help":
		return .HELP
	}
	return .UNKNOWN
}


