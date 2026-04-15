// theme_starship.odin - Starship prompt integration for wayu
//
// This module provides Starship cross-shell prompt integration:
// - Detect starship: which starship
// - wayu theme enable starship - Enable starship integration
// - Generate starship.toml if missing
// - Configure shell to use starship

package wayu

import "core:fmt"
import "core:os"
import "core:strings"

// Starship configuration paths
STARSHIP_CONFIG_DIR :: "~/.config"
STARSHIP_CONFIG_FILE :: "starship.toml"

// ============================================================================
// Public API
// ============================================================================

// theme_detect_starship :: proc() -> bool
// Detects if Starship is installed on the system
theme_detect_starship :: proc() -> bool {
	// Try to find starship in PATH
	if command_exists("starship") {
		return true
	}

	// Check common installation paths
	common_paths := []string{
		"/usr/local/bin/starship",
		"/usr/bin/starship",
		"~/.local/bin/starship",
		"~/.cargo/bin/starship",
		"/opt/homebrew/bin/starship",  // macOS Homebrew
		"/home/linuxbrew/.linuxbrew/bin/starship",  // Linux Homebrew
	}

	home := os.get_env("HOME", context.temp_allocator)

	for path in common_paths {
		expanded_path, _ := strings.replace(path, "~", home, 1)
		defer delete(expanded_path)

		if os.exists(expanded_path) {
			return true
		}
	}

	return false
}

// theme_generate_starship_config :: proc() -> string
// Generates a default starship.toml configuration
theme_generate_starship_config :: proc() -> string {
	return generate_starship_toml()
}

// theme_starship_apply :: proc() -> bool
// Applies Starship integration - called by theme_apply when name is "starship"
theme_starship_apply :: proc() -> bool {
	// 1. Verify starship is installed
	if !theme_detect_starship() {
		print_error("Starship is not installed")
		fmt.println()
		fmt.printfln("Install Starship with one of these methods:")
		fmt.println()
		fmt.printfln("  %sOfficial installer:%s", get_primary(), RESET)
		fmt.printfln("    sh -c \"$(curl -fsSL https://starship.rs/install.sh)\"")
		fmt.println()
		fmt.printfln("  %sHomebrew (macOS/Linux):%s", get_primary(), RESET)
		fmt.printfln("    brew install starship")
		fmt.println()
		fmt.printfln("  %sCargo:%s", get_primary(), RESET)
		fmt.printfln("    cargo install starship")
		return false
	}

	// 2. Get starship version info
	starship_version := get_starship_version()
	defer delete(starship_version)

	if len(starship_version) > 0 {
		print_info("Detected Starship %s", starship_version)
	}

	// 3. Ensure starship.toml exists
	starship_config_path := get_starship_config_path()
	defer delete(starship_config_path)

	if !os.exists(starship_config_path) {
		print_info("Creating default starship.toml...")

		// Ensure config directory exists
		home_dir := os.get_env("HOME", context.temp_allocator)
		config_dir := fmt.aprintf("%s/.config", home_dir)
		defer delete(config_dir)

		if !os.exists(config_dir) {
			err := os.make_directory(config_dir)
			if err != nil {
				print_error("Failed to create config directory: %v", err)
				return false
			}
		}

		// Generate default config
		config_content := generate_starship_toml()
		defer delete(config_content)

		if !safe_write_file(starship_config_path, transmute([]byte)config_content) {
			print_error("Failed to write starship.toml")
			return false
		}

		print_success("Created %s", starship_config_path)
	}

	// 4. Update active theme
	if !write_active_theme("starship", "starship") {
		return false
	}

	// 5. Apply to shell configuration
	if !apply_starship_to_shell() {
		return false
	}

	return true
}

// ============================================================================
// Shell Configuration
// ============================================================================

// Generate shell configuration for Starship
generate_starship_shell_config :: proc() -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	fmt.sbprintln(&builder, "# WAYU THEME BEGIN - starship")
	fmt.sbprintln(&builder, "# Starship cross-shell prompt")
	fmt.sbprintln(&builder, "")

	// Detect shell and generate appropriate initialization
	switch DETECTED_SHELL {
	case .ZSH:
		fmt.sbprintln(&builder, "# Initialize Starship for Zsh")
		fmt.sbprintln(&builder, "if command -v starship &> /dev/null; then")
		fmt.sbprintln(&builder, "  eval \"$(starship init zsh)\"")
		fmt.sbprintln(&builder, "fi")
	case .BASH:
		fmt.sbprintln(&builder, "# Initialize Starship for Bash")
		fmt.sbprintln(&builder, "if command -v starship &> /dev/null; then")
		fmt.sbprintln(&builder, "  eval \"$(starship init bash)\"")
		fmt.sbprintln(&builder, "fi")
	case .FISH:
		fmt.sbprintln(&builder, "# Initialize Starship for Fish")
		fmt.sbprintln(&builder, "if command -v starship &> /dev/null; then")
		fmt.sbprintln(&builder, "  eval \"$(starship init fish)\"")
		fmt.sbprintln(&builder, "fi")
	case .UNKNOWN:
		fmt.sbprintln(&builder, "# Initialize Starship (unknown shell)")
		fmt.sbprintln(&builder, "if command -v starship &> /dev/null; then")
		fmt.sbprintln(&builder, "  echo \"Starship detected but shell not recognized\"")
		fmt.sbprintln(&builder, "fi")
	}

	fmt.sbprintln(&builder, "")
	fmt.sbprintln(&builder, "# WAYU THEME END")

	return strings.clone(strings.to_string(builder))
}

// Apply Starship configuration to shell init file
apply_starship_to_shell :: proc() -> bool {
	// Read the init file
	init_file := fmt.aprintf("%s/%s", WAYU_CONFIG, INIT_FILE)
	defer delete(init_file)

	if !os.exists(init_file) {
		print_error("Wayu not initialized. Run 'wayu init' first.")
		return false
	}

	file_content, ok := safe_read_file(init_file)
	if !ok {
		print_error("Failed to read init file: %s", init_file)
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

	// If no theme section found, add one
	if !found_theme_section {
		// Add theme section before the final export
		insert_idx := len(new_lines)

		// Look for a good insertion point (before the PATH export)
		for i := len(new_lines) - 1; i >= 0; i -= 1 {
			if strings.contains(new_lines[i], "export PATH") {
				insert_idx = i
				break
			}
		}

		// Insert starship configuration
		starship_config := generate_starship_shell_config()
		defer delete(starship_config)

		starship_lines := strings.split(starship_config, "\n")
		defer delete(starship_lines)

		for starship_line in starship_lines {
			inject_at(&new_lines, insert_idx, strings.clone(starship_line))
			insert_idx += 1
		}
	} else {
		// Re-add starship section with new config
		for i := 0; i < len(new_lines); i += 1 {
			if strings.contains(new_lines[i], "# WAYU THEME BEGIN") {
				starship_config := generate_starship_shell_config()
				defer delete(starship_config)

				starship_lines := strings.split(starship_config, "\n")
				defer delete(starship_lines)

				// Insert after BEGIN (skip BEGIN line and content until END)
				for j := 1; j < len(starship_lines); j += 1 {
					if strings.contains(starship_lines[j], "END") {
						break
					}
					inject_at(&new_lines, i + j, strings.clone(starship_lines[j]))
				}
				break
			}
		}
	}

	// Write updated content
	final_content := strings.join(new_lines[:], "\n")
	defer delete(final_content)

	if !safe_write_file(init_file, transmute([]byte)final_content) {
		print_error("Failed to write init file: %s", init_file)
		return false
	}

	return true
}

// ============================================================================
// Starship Configuration
// ============================================================================

// Get the full path to starship.toml
get_starship_config_path :: proc() -> string {
	home := os.get_env("HOME", context.temp_allocator)
	return fmt.aprintf("%s/.config/starship.toml", home)
}

// Get Starship version
get_starship_version :: proc() -> string {
	output := capture_command([]string{"starship", "--version"})
	if len(output) == 0 {
		return ""
	}

	// Parse version from output like "starship 1.16.0"
	lines := strings.split(output, "\n")
	defer delete(lines)

	if len(lines) > 0 {
		parts := strings.split(lines[0], " ")
		defer delete(parts)

		if len(parts) >= 2 {
			return strings.clone(parts[1])
		}
	}

	return ""
}

// Generate a default starship.toml configuration
generate_starship_toml :: proc() -> string {
	return `"
# Starship configuration for wayu
# https://starship.rs/config/

format = """
$username$hostname$directory$git_branch$git_status$cmd_duration$line_break$character"""

[character]
success_symbol = "[❯](green)"
error_symbol = "[❯](red)"
vimcmd_symbol = "[❮](green)"

[directory]
truncation_length = 3
truncate_to_repo = true
truncation_symbol = "…/"

[git_branch]
symbol = ""
format = "[$symbol$branch]($style) "

[git_status]
format = '([$all_status$ahead_behind]($style) )'
ahead = "⇡${count}"
behind = "⇣${count}"
diverged = "⇕⇡${ahead_count}⇣${behind_count}"
conflicted = "=${count}"
deleted = "✘${count}"
renamed = "»${count}"
modified = "!${count}"
staged = "+${count}"
stashed = "\\$${count}"
untracked = "?${count}"

[cmd_duration]
min_time = 2000
format = "took [$duration]($style) "

[username]
style_user = "blue bold"
style_root = "red bold"
format = "[$user]($style) "
disabled = false
show_always = false

[hostname]
ssh_only = true
format = "[$hostname]($style) in "
style = "bold dimmed green"
disabled = false
`
}

// ============================================================================
// Utility Functions
// ============================================================================

// Get Starship installation instructions for the current platform
get_starship_install_instructions :: proc() -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	fmt.sbprintln(&builder, "Install Starship with one of these methods:")
	fmt.sbprintln(&builder, "")

	// Detect platform and provide appropriate instructions
	if os.exists("/usr/bin/apt") || os.exists("/usr/bin/apt-get") {
		fmt.sbprintln(&builder, "  Debian/Ubuntu:")
		fmt.sbprintln(&builder, "    curl -sS https://starship.rs/install.sh | sh")
		fmt.sbprintln(&builder, "")
	}

	if os.exists("/usr/bin/brew") || os.exists("/opt/homebrew/bin/brew") {
		fmt.sbprintln(&builder, "  Homebrew (macOS/Linux):")
		fmt.sbprintln(&builder, "    brew install starship")
		fmt.sbprintln(&builder, "")
	}

	if os.exists("/usr/bin/pacman") {
		fmt.sbprintln(&builder, "  Arch Linux:")
		fmt.sbprintln(&builder, "    pacman -S starship")
		fmt.sbprintln(&builder, "")
	}

	// Generic instructions
	fmt.sbprintln(&builder, "  Universal (requires curl):")
	fmt.sbprintln(&builder, "    curl -sS https://starship.rs/install.sh | sh")
	fmt.sbprintln(&builder, "")
	fmt.sbprintln(&builder, "  Cargo (requires Rust):")
	fmt.sbprintln(&builder, "    cargo install starship")

	return strings.clone(strings.to_string(builder))
}
