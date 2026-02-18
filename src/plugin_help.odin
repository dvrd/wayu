package wayu

import "core:fmt"

// Help text

print_plugin_help :: proc() {
	// Title
	fmt.printf("\n%s%swayu plugin - Plugin management%s\n\n", BOLD, get_primary(), RESET)

	// Usage section
	fmt.printf("%s%sUSAGE:%s\n", BOLD, get_secondary(), RESET)
	fmt.println("  wayu plugin <action> [arguments]")

	// Actions section
	fmt.printf("\n%s%sACTIONS:%s\n", BOLD, get_secondary(), RESET)
	fmt.println("  add <name-or-url>       Install plugin")
	fmt.println("  remove [name]           Remove plugin (interactive if no name)")
	fmt.println("  list                    List installed plugins")
	fmt.println("  enable <name>           Enable disabled plugin")
	fmt.println("  disable <name>          Disable plugin without removing")
	fmt.println("  priority <name> <num>   Set plugin load priority (lower = earlier)")
	fmt.println("  get <name>              Show plugin info and copy URL to clipboard")
	fmt.println("  check                   Check all plugins for updates")
	fmt.println("  update <name|--all>     Update specific plugin or all plugins")
	fmt.println("  help                    Show this help message")

	// Examples section
	fmt.printf("\n%s%sEXAMPLES:%s\n", BOLD, get_secondary(), RESET)
	fmt.printf("  %s# Install popular plugin%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin add syntax-highlighting%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Install from URL%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin add https://github.com/user/plugin.git%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Show all plugins%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin list%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Get plugin info + copy URL%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin get syntax-highlighting%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Interactive removal%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin remove%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Check for plugin updates%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin check%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Update specific plugin%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin update zsh-autosuggestions%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Update all plugins%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin update --all%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Temporarily disable a plugin%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin disable zsh-autosuggestions%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Re-enable a disabled plugin%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin enable zsh-autosuggestions%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Set load priority (lower loads first)%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin priority zsh-autosuggestions 50%s\n", get_muted(), RESET)

	// Popular plugins section
	fmt.printf("\n%s%sPOPULAR PLUGINS:%s\n", BOLD, get_secondary(), RESET)
	count := 0
	for name, info in POPULAR_PLUGINS {
		if count >= 5 {
			break
		}
		fmt.printf("  %s• %s - %s%s\n", get_muted(), name, info.description, RESET)
		count += 1
	}
	fmt.println()
}

print_plugin_add_help :: proc() {
	// Title
	fmt.printf("\n%s%swayu plugin add - Install plugin%s\n\n", BOLD, get_primary(), RESET)

	// Usage section
	fmt.printf("%s%sUSAGE:%s\n", BOLD, get_secondary(), RESET)
	fmt.println("  wayu plugin add <name-or-url>")

	// Examples section
	fmt.printf("\n%s%sEXAMPLES:%s\n", BOLD, get_secondary(), RESET)
	fmt.printf("  %swayu plugin add syntax-highlighting%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin add https://github.com/user/plugin.git%s\n", get_muted(), RESET)
	fmt.println()
}
