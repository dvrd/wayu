// templates.odin - Configuration presets for common setups
#+feature dynamic-literals
//
// Provides ready-to-use configurations for common use cases like
// development environments, minimal setups, etc.

package wayu

import "core:fmt"
import "core:os"
import "core:strings"

// Template definition
ConfigTemplate :: struct {
	name:        string,
	description: string,
	apply:       proc(),
}

// Template names for reference
template_names := []string{"developer", "minimal", "data-science", "full"}

// Handle template command
handle_template_command :: proc(action: Action, args: []string) {
	#partial switch action {
	case .LIST:
		list_templates()
	case .ADD:
		if len(args) == 0 {
			print_error("Usage: wayu init --template <name>")
			fmt.println()
			list_templates()
			os.exit(EXIT_USAGE)
		}
		apply_template(args[0])
	case .HELP:
		print_template_usage()
	case:
		print_template_usage()
	}
}

// List available templates
list_templates :: proc() {
	print_header("Configuration Templates", "📋")
	fmt.println()

	template_list := []struct {
		name:        string,
		description: string,
	}{
		{"developer", "Common dev tools: cargo, npm, go, homebrew paths"},
		{"minimal", "Only essential paths, fastest startup"},
		{"data-science", "Python, conda, jupyter, common ML tools"},
		{"full", "All common paths for power users"},
	}

	for t in template_list {
		fmt.printfln("  %s%s%s", get_primary(), t.name, RESET)
		fmt.printfln("    %s%s%s", get_muted(), t.description, RESET)
		fmt.println()
	}

	fmt.printfln("%sUsage:%s", get_secondary(), RESET)
	fmt.println("  wayu init --template developer")
	fmt.println()
	fmt.printfln("%sOr apply to existing config:%s", get_secondary(), RESET)
	fmt.println("  wayu template apply developer")
}

// Apply a template
apply_template :: proc(name: string) {
	switch name {
	case "developer":
		apply_developer_template()
	case "minimal":
		apply_minimal_template()
	case "data-science", "ds":
		apply_datascience_template()
	case "full":
		apply_full_template()
	case:
		print_error("Unknown template: %s", name)
		fmt.println()
		list_templates()
		os.exit(EXIT_DATAERR)
	}
}

// Shared helpers so each template routes through the TOML-first add paths
// instead of the legacy shell-file writer (add_config_entry). Without this,
// fish users ended up with aliases.fish/constants.fish that shipped bash
// syntax (`alias g="git"`, `export EDITOR=...`) while wayu.toml stayed
// empty.

template_add_paths :: proc(paths: []string) {
	if !ensure_wayu_toml_exists() {
		print_error_simple("Failed to create wayu.toml")
		return
	}
	for p in paths {
		fmt.printfln("  Adding: %s%s%s", get_muted(), p, RESET)
		if !toml_path_add(p) {
			print_warning("  skipped (could not write): %s", p)
		}
	}
}

template_add_aliases :: proc(aliases: []struct{name, command: string}) {
	if !ensure_wayu_toml_exists() {
		print_error_simple("Failed to create wayu.toml")
		return
	}
	for a in aliases {
		fmt.printfln("  Adding alias: %s%s%s = %s", get_primary(), a.name, RESET, a.command)
		entry := ConfigEntry{type = .ALIAS, name = a.name, value = a.command}
		if ok, err := toml_alias_add(entry); !ok {
			print_warning("  skipped %s: %s", a.name, err)
			delete(err)
		}
	}
}

template_add_constants :: proc(consts: []struct{name, value: string}) {
	if !ensure_wayu_toml_exists() {
		print_error_simple("Failed to create wayu.toml")
		return
	}
	for c in consts {
		fmt.printfln("  Adding constant: %s%s%s = %s", get_primary(), c.name, RESET, c.value)
		entry := ConfigEntry{type = .CONSTANT, name = c.name, value = c.value}
		if ok, err := toml_constant_add(entry); !ok {
			print_warning("  skipped %s: %s", c.name, err)
			delete(err)
		}
	}
}

// Developer template
apply_developer_template :: proc() {
	print_header("Applying Developer Template", "💻")
	fmt.println()

	template_add_paths([]string{
		"/opt/homebrew/bin",
		"/usr/local/bin",
		"$HOME/.cargo/bin",
		"$HOME/.local/bin",
		"$HOME/.npm-global/bin",
		"$HOME/go/bin",
	})

	fmt.println()
	template_add_aliases([]struct{name, command: string}{
		{"g", "git"},
		{"gs", "git status"},
		{"gcm", "git commit -m"},
		{"gp", "git push"},
		{"code", "code ."},
	})

	fmt.println()
	template_add_constants([]struct{name, value: string}{
		{"EDITOR", "code --wait"},
		{"GOPATH", "$HOME/go"},
	})

	fmt.println()
	regenerate_init_core_silently()
	print_success("Developer template applied! Reload your shell to activate.")
}

// Minimal template
apply_minimal_template :: proc() {
	print_header("Applying Minimal Template", "⚡")
	fmt.println()

	fmt.println("  Minimal template: Only essential system paths")
	fmt.println("  No aliases or constants added")

	print_success("Minimal template applied!")
}

// Data science template
apply_datascience_template :: proc() {
	print_header("Applying Data Science Template", "📊")
	fmt.println()

	template_add_paths([]string{
		"/opt/homebrew/anaconda3/bin",
		"$HOME/.conda/bin",
		"$HOME/.local/bin",
		"/usr/local/bin",
	})

	fmt.println()
	template_add_aliases([]struct{name, command: string}{
		{"jlab", "jupyter lab"},
		{"jnb", "jupyter notebook"},
		{"py", "python3"},
		{"pip", "pip3"},
	})

	fmt.println()
	regenerate_init_core_silently()
	print_success("Data Science template applied! Reload your shell to activate.")
}

// Full template
apply_full_template :: proc() {
	print_header("Applying Full Template", "🔥")
	fmt.println()

	template_add_paths([]string{
		"/opt/homebrew/bin",
		"/usr/local/bin",
		"$HOME/.cargo/bin",
		"$HOME/.local/bin",
		"$HOME/.npm-global/bin",
		"$HOME/go/bin",
		"$HOME/.julia/bin",
		"$HOME/.deno/bin",
		"$HOME/.bun/bin",
	})

	fmt.println()
	regenerate_init_core_silently()
	print_success("Full template applied! Reload your shell to activate.")
}

// Print template usage
print_template_usage :: proc() {
	fmt.println()
	fmt.printfln("%swayu template - Configuration presets%s", BOLD, RESET)
	fmt.println()
	fmt.printfln("%sUSAGE:%s", get_primary(), RESET)
	fmt.printfln("  wayu template list           List available templates")
	fmt.printfln("  wayu template apply <name>   Apply a template to current config")
	fmt.printfln("  wayu init --template <name>   Initialize with template")
	fmt.println()
	fmt.printfln("%sAVAILABLE TEMPLATES:%s", get_primary(), RESET)
	fmt.println("  developer     - Common dev tools (cargo, npm, go)")
	fmt.println("  minimal       - Fastest startup, essential only")
	fmt.println("  data-science  - Python, conda, jupyter")
	fmt.println("  full          - Everything for power users")
	fmt.println()
	fmt.printfln("%sEXAMPLES:%s", get_primary(), RESET)
	fmt.println("  wayu init --template developer")
	fmt.println("  wayu template apply data-science")
}
