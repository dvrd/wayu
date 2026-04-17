// wayu_completions.odin - Auto-generate completions for wayu itself
//
// This module generates Zsh completion scripts for wayu commands,
// enabling tab-completion for the CLI.

package wayu

import "core:fmt"
import "core:os"
import "core:strings"
import "core:path/filepath"

// Completion script template for Zsh
WAYU_COMPLETION_TEMPLATE :: `#compdef wayu

# wayu completion script - Auto-generated
# Regenerate with: wayu completions generate

_wayu_commands() {
    local commands
    commands=(
        'path:Manage PATH entries'
        'alias:Manage shell aliases'
        'constants:Manage environment constants'
        'search:Fuzzy search across all configs'
        'find:Fuzzy search alias'
        'f:Fuzzy search short alias'
        'completions:Manage Zsh completion scripts'
        'backup:Manage configuration backups'
        'plugin:Manage shell plugins'
        'init:Initialize wayu configuration'
        'migrate:Migrate between shells'
        'config:Open extra config in EDITOR'
        'export:Generate turbo export file'
        'toml:TOML configuration management'
        'version:Show version'
        'help:Show help'
    )
    _describe -t commands 'wayu command' commands
}

_wayu_path_actions() {
    local actions
    actions=(
        'add:Add a PATH entry'
        'remove:Remove a PATH entry'
        'rm:Remove path entry'
        'list:List PATH entries'
        'ls:List path entries'
        'get:Get PATH by name'
        'clean:Remove missing directories'
        'dedup:Remove duplicates'
        'help:Show help'
    )
    _describe -t actions 'path action' actions
}

_wayu_alias_actions() {
    local actions
    actions=(
        'add:Add an alias'
        'remove:Remove an alias'
        'rm:Remove alias'
        'list:List aliases'
        'ls:List alias'
        'get:Get alias value'
        'help:Show help'
    )
    _describe -t actions 'alias action' actions
}

_wayu_constants_actions() {
    local actions
    actions=(
        'add:Add a constant'
        'remove:Remove a constant'
        'rm:Remove constant'
        'list:List constants'
        'ls:List constants'
        'get:Get constant value'
        'help:Show help'
    )
    _describe -t actions 'constants action' actions
}

_wayu_plugin_actions() {
    local actions
    actions=(
        'add:Install a plugin'
        'remove:Remove a plugin'
        'list:List installed plugins'
        'search:Search registry'
        'enable:Enable plugin'
        'disable:Disable plugin'
        'priority:Set plugin priority'
        'check:Check for updates'
        'update:Update plugins'
        'help:Show help'
    )
    _describe -t actions 'plugin action' actions
}

_wayu_backup_actions() {
    local actions
    actions=(
        'list:List backups'
        'restore:Restore from backup'
        'help:Show help'
    )
    _describe -t actions 'backup action' actions
}

_wayu_completions_actions() {
    local actions
    actions=(
        'add:Add completion script'
        'list:List completions'
        'help:Show help'
    )
    _describe -t actions 'completions action' actions
}

_wayu_export_actions() {
    local actions
    actions=(
        'turbo:Generate turbo file'
        'eval:Output for eval'
        'list:Show formats'
        'help:Show help'
    )
    _describe -t actions 'export action' actions
}

_wayu_toml_actions() {
    local actions
    actions=(
        'validate:Validate TOML config'
        'convert:Convert to TOML'
        'apply:Apply TOML config'
        'help:Show help'
    )
    _describe -t actions 'toml action' actions
}

# Main completion function
_wayu() {
    local curcontext="$curcontext" state line
    typeset -A opt_args

    _arguments -C \
        '(-h --help)'{-h,--help}'[Show help]' \
        '(-v --version)'{-v,--version}'[Show version]' \
        '(-n --dry-run)'{-n,--dry-run}'[Preview changes]' \
        '(-y --yes)'{-y,--yes}'[Skip confirmation]' \
        '--tui[Launch TUI mode]' \
        '--shell[Specify shell]:shell:(zsh bash)' \
        '1: :_wayu_commands' \
        '2: :->action' \
        '*:: :->args'

    case "$state" in
        action)
            case "$line[1]" in
                path) _wayu_path_actions ;;
                alias) _wayu_alias_actions ;;
                constants|const) _wayu_constants_actions ;;
                plugin) _wayu_plugin_actions ;;
                backup) _wayu_backup_actions ;;
                completions) _wayu_completions_actions ;;
                export) _wayu_export_actions ;;
                toml) _wayu_toml_actions ;;
            esac
            ;;
        args)
            case "$line[1]" in
                path)
                    if [[ "$line[2]" == "add" ]]; then
                        _path_files -/
                    fi
                    ;;
                completions)
                    if [[ "$line[2]" == "add" ]]; then
                        _files
                    fi
                    ;;
            esac
            ;;
    esac
}

compdef _wayu wayu
`

// Generate completions for wayu itself
handle_completions_generate :: proc() {
	print_header("Generating wayu completions", "🎯")
	fmt.println()

	// Determine completions directory
	completions_dir := fmt.aprintf("%s/completions", WAYU_CONFIG)
	defer delete(completions_dir)

	// Ensure directory exists
	if !os.exists(completions_dir) {
		err := os.make_directory(completions_dir)
		if err != nil {
			print_error("Failed to create completions directory: %v", err)
			os.exit(EXIT_CANTCREAT)
		}
	}

	// Write completion file
	completion_path := fmt.aprintf("%s/_wayu", completions_dir)
	defer delete(completion_path)

	write_ok := safe_write_file(completion_path, transmute([]byte)(string(WAYU_COMPLETION_TEMPLATE)))
	if !write_ok {
		print_error("Failed to write completion file")
		os.exit(EXIT_IOERR)
	}

	print_success("Generated: %s", completion_path)
	fmt.println()

	// Instructions
	print_section("Setup Instructions", EMOJI_INFO)
	fmt.println("The completion script has been generated. To enable it:")
	fmt.println()
	fmt.println("Option 1 - Add to fpath (recommended):")
	fmt.printfln("  fpath=(%s $fpath)", completions_dir)
	fmt.println("  compinit")
	fmt.println()
	fmt.println("Option 2 - Source directly in .zshrc:")
	fmt.printfln("  source %s", completion_path)
	fmt.println()
	fmt.println("Then restart your shell or run:")
	fmt.println("  exec zsh")
	fmt.println()
	print_success("Tab completion now available: wayu <TAB>")
}

// Extended completions handler with generate action.
// All regular actions delegate to the main completions handler.
handle_completions_command_extended :: proc(action: Action, args: []string) {
	#partial switch action {
	case .ADD, .REMOVE, .GET, .RESTORE, .CLEAN, .DEDUP, .UNKNOWN:
		handle_completions_command(action, args)
	case .LIST:
		for arg in args {
			if arg == "--generate" || arg == "-g" || arg == "generate" {
				handle_completions_generate()
				return
			}
		}
		handle_completions_command(.LIST, args)
	case .HELP:
		print_completions_help_extended()
	case .UPDATE:
		handle_completions_generate()
	case:
		handle_completions_command(action, args)
	}
}

// Print extended completions help with generate option
print_completions_help_extended :: proc() {
	fmt.println()
	fmt.printfln("%swayu completions - Manage shell completions%s", BOLD, RESET)
	fmt.println()
	fmt.printfln("%sUSAGE:%s", get_primary(), RESET)
	fmt.printfln("  wayu completions list              List installed completions")
	fmt.printfln("  wayu completions generate          Generate wayu self-completions")
	fmt.printfln("  wayu completions add <name> <path> Add completion script")
	fmt.println()
	fmt.printfln("%sDESCRIPTION:%s", get_primary(), RESET)
	fmt.println("  Manage Zsh completion scripts for enhanced tab-completion.")
	fmt.println()
	fmt.printfln("%sSELF-COMPLETIONS:%s", get_primary(), RESET)
	fmt.println("  wayu can generate its own completion script for tab completion.")
	fmt.println("  Run 'wayu completions generate' and follow the setup instructions.")
	fmt.println()
	fmt.printfln("%sEXAMPLES:%s", get_primary(), RESET)
	fmt.println("  wayu completions generate")
	fmt.println("  # Then add to .zshrc: fpath=(~/.config/wayu/completions $fpath)")
	fmt.println("  wayu completions add jj /path/to/_jj")
}

// List existing completions (existing function wrapper)
handle_completions_list :: proc() {
	// Call original completions list
	handle_completions_command(.LIST, nil)
}
