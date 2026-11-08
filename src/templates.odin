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
			print_error("Usage: wayu template apply <name>")
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

// True when `name` names a template apply_template knows.
template_exists :: proc(name: string) -> bool {
	switch name {
	case "developer", "minimal", "data-science", "ds", "full": return true
	}
	return false
}

// `wayu init --template NAME` / `--template=NAME`: the template to apply
// after init ("" when none). Exits 64 on a missing value and 65 on an
// unknown template, before init writes anything.
init_template_arg :: proc(args: []string) -> string {
	name := ""
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		switch {
		case a == "--template":
			if i + 1 >= len(args) || strings.has_prefix(args[i + 1], "-") {
				print_error_simple("--template requires a template name")
				list_templates()
				os.exit(EXIT_USAGE)
			}
			name = args[i + 1]
			i += 1
		case strings.has_prefix(a, "--template="):
			name = a[len("--template="):]
		case:
			print_error_simple("Unexpected argument for init: %s", a)
			fmt.eprintln("Usage: wayu init [--template <name>]")
			os.exit(EXIT_USAGE)
		}
	}
	if len(name) > 0 && !template_exists(name) {
		print_error_simple("Unknown template: %s", name)
		list_templates()
		os.exit(EXIT_DATAERR)
	}
	return name
}

// What one template apply did (or, under --dry-run, would do).
@(private = "file")
template_added, template_skipped: int

// Apply a template. Entries already present are kept (never overwritten):
// a [paths] directory already listed, an alias or [env] name already in
// wayu.toml, or a constant already set in the environment wayu runs in.
// --dry-run prints what would be added/skipped and writes nothing.
apply_template :: proc(name: string) {
	template_added, template_skipped = 0, 0
	if wayu.dry_run {
		print_header("DRY RUN - No changes will be made", EMOJI_INFO)
	}
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

// Keys of wayu.toml [section] as they are on disk now (temp allocator).
@(private = "file")
template_existing_keys :: proc(section: string) -> map[string]bool {
	keys := make(map[string]bool, allocator = context.temp_allocator)
	toml_path := fmt.tprintf("%s/%s", wayu.config, WAYU_TOML)
	if !os.exists(toml_path) { return keys }
	content, ok := safe_read_file(toml_path)
	if !ok { return keys }
	defer delete(content)
	kvs := toml_read_section(string(content), section)
	defer destroy_toml_kvs(&kvs)
	for kv in kvs { keys[strings.clone(kv.key, context.temp_allocator)] = true }
	return keys
}

@(private = "file")
template_report :: proc(verb, what: string, skipped_why := "") {
	if len(skipped_why) > 0 {
		template_skipped += 1
		fmt.printfln("  %sKeeping%s %s %s(%s)%s", get_muted(), RESET, what, get_muted(), skipped_why, RESET)
		return
	}
	template_added += 1
	fmt.printfln("  %s %s %s", wayu.dry_run ? "Would add" : "Adding", verb, what)
}

template_add_paths :: proc(paths: []string) {
	toml_path := fmt.tprintf("%s/%s", wayu.config, WAYU_TOML)
	if !wayu.dry_run && !ensure_wayu_toml_exists() {
		print_error_simple("Failed to create wayu.toml")
		os.exit(EXIT_CANTCREAT)
	}
	for p in paths {
		what := fmt.tprintf("%s%s%s", get_muted(), p, RESET)
		if os.exists(toml_path) && !toml_path_add_would_change(p) {
			template_report("path", what, "already in wayu.toml")
			continue
		}
		if wayu.dry_run {
			template_report("path", what)
			continue
		}
		switch toml_path_add_result(p) {
		case .OK:   template_report("path", what)
		case .NOOP: template_report("path", what, "already in wayu.toml")
		case .INVALID, .NOT_FOUND, .IO_ERROR:
			print_warning("  skipped (could not write): %s", p)
		}
	}
}

template_add_aliases :: proc(aliases: []struct{name, command: string}) {
	if !wayu.dry_run && !ensure_wayu_toml_exists() {
		print_error_simple("Failed to create wayu.toml")
		os.exit(EXIT_CANTCREAT)
	}
	existing := template_existing_keys("aliases")
	for a in aliases {
		what := fmt.tprintf("%s%s%s = %s", get_primary(), a.name, RESET, a.command)
		if a.name in existing {
			template_report("alias", what, "your alias is kept")
			continue
		}
		template_report("alias", what)
		if wayu.dry_run { continue }
		entry := ConfigEntry{type = .ALIAS, name = a.name, value = a.command}
		if ok, err := toml_alias_add(entry); !ok {
			print_warning("  skipped %s: %s", a.name, err)
			delete(err)
		}
	}
}

template_add_constants :: proc(consts: []struct{name, value: string}) {
	if !wayu.dry_run && !ensure_wayu_toml_exists() {
		print_error_simple("Failed to create wayu.toml")
		os.exit(EXIT_CANTCREAT)
	}
	existing := template_existing_keys("env")
	for c in consts {
		what := fmt.tprintf("%s%s%s = %s", get_primary(), c.name, RESET, c.value)
		if c.name in existing {
			template_report("constant", what, "your value in wayu.toml is kept")
			continue
		}
		if v, set := os.lookup_env(c.name, context.temp_allocator); set && len(v) > 0 {
			template_report("constant", what, fmt.tprintf("already set in your environment: %s", v))
			continue
		}
		template_report("constant", what)
		if wayu.dry_run { continue }
		entry := ConfigEntry{type = .CONSTANT, name = c.name, value = c.value}
		if ok, err := toml_constant_add(entry); !ok {
			print_warning("  skipped %s: %s", c.name, err)
			delete(err)
		}
	}
}

// Regenerate the shell init (unless --dry-run) and print the outcome.
@(private = "file")
template_finish :: proc(title: string) {
	fmt.println()
	if wayu.dry_run {
		fmt.printfln("%s template: would add %d entr%s, keep %d existing. Nothing was written.",
			title, template_added, template_added == 1 ? "y" : "ies", template_skipped)
		return
	}
	regenerate_init_core_silently()
	print_success("%s template applied: %d added, %d kept. Reload your shell to activate.",
		title, template_added, template_skipped)
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
		// No `code = "code ."`: an alias named like the binary shadows it
		// (`code file.txt` opened the cwd).
	})

	fmt.println()
	template_add_constants([]struct{name, value: string}{
		{"EDITOR", "code --wait"},
		{"GOPATH", "$HOME/go"},
	})

	template_finish("Developer")
}

// Minimal template
apply_minimal_template :: proc() {
	print_header("Applying Minimal Template", "⚡")
	fmt.println()

	fmt.println("  Minimal template: Only essential system paths")
	fmt.println("  No aliases or constants added")

	fmt.println()
	if wayu.dry_run {
		fmt.println("Minimal template: nothing to add. Nothing was written.")
		return
	}
	print_success("Minimal template applied (nothing to add)")
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

	template_finish("Data Science")
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

	template_finish("Full")
}

// Print template usage
print_template_usage :: proc() {
	fmt.println()
	fmt.printfln("%swayu template - Configuration presets%s", BOLD, RESET)
	fmt.println()
	fmt.printfln("%sUSAGE:%s", get_primary(), RESET)
	fmt.printfln("  wayu template list           List available templates")
	fmt.printfln("  wayu template apply <name>   Apply a template to current config")
	fmt.printfln("  wayu init --template <name>  Initialize, then apply a template")
	fmt.println()
	fmt.println("  Existing entries are kept: a template never overwrites an alias or")
	fmt.println("  constant you already have. --dry-run shows what would be added.")
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
