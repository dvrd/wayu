package wayu

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// Shell compatibility for plugins.
// BOTH = works on zsh AND bash.
// ANY  = works on all supported shells including fish.
ShellCompat :: enum {
	ZSH,
	BASH,
	BOTH,  // zsh + bash
	FISH,
	ANY,   // zsh + bash + fish
}

// True if a plugin with compat `pc` should be loaded under runtime shell `rt`.
plugin_compat_matches :: proc(pc: ShellCompat, rt: ShellType) -> bool {
	#partial switch rt {
	case .ZSH:  return pc == .ZSH  || pc == .BOTH || pc == .ANY
	case .BASH: return pc == .BASH || pc == .BOTH || pc == .ANY
	case .FISH: return pc == .FISH || pc == .ANY
	}
	return false
}

// Plugin information from registry
PluginInfo :: struct {
	name:        string,
	url:         string,
	shell:       ShellCompat,
	description: string,
}

// Plugin source types (inspired by sheldon - natively integrated)
PluginSourceType :: enum {
	GitHub,      // github.com/owner/repo
	GitLab,      // gitlab.com/owner/repo  
	Gist,        // gist.github.com/hash
	Git,         // Generic git URL
	Remote,      // Direct file URL (curl/wget)
	Local,       // Local directory
}

// Template for plugin loading (wayu-native, inspired by sheldon)
PluginLoadTemplate :: enum {
	Source,      // source "{{file}}"
	Path,        // export PATH="{{dir}}:$PATH"
	FPath,       // export FPATH="{{dir}}:$FPATH" (completions)
	Autoload,    // autoload -Uz {{name}}
	Eval,        // eval "$({{file}})"
}

// Enhanced plugin metadata with sheldon-inspired features (wayu-native)
PluginMetadata :: struct {
	name:           string,
	display_name:   string,  // Human-readable name
	url:            string,  // Clone/download URL
	source_type:    PluginSourceType,
	enabled:        bool,
	shell:          ShellCompat,
	installed_path: string,
	entry_file:     string,  // Deprecated: use 'use' globs instead
	
	// File selection (sheldon-inspired 'use' field)
	use:            [dynamic]string,  // Globs: ["*.zsh", "*.plugin.zsh"]
	
	// Template system (wayu-native)
	template:       PluginLoadTemplate,  // How to load this plugin
	
	// Git tracking with version pinning (sheldon-inspired)
	git:            GitMetadata,
	
	// Dependencies and conflicts
	dependencies:   [dynamic]string,
	priority:       int,  // Load order (lower = earlier)
	
	// Profile system (wayu-native, inspired by sheldon)
	profiles:       [dynamic]string,  // Empty = all profiles
	
	// Conflict detection
	conflicts:      ConflictInfo,
}

// Git metadata with version pinning (wayu-native, sheldon-inspired)
GitMetadata :: struct {
	ref_type:      GitRefType,  // Branch, Tag, or Commit
	branch:        string,      // Active branch name
	tag:           string,      // Tag if pinned to tag
	commit:        string,      // Current commit SHA (short form)
	pinned_ref:    string,      // The actual pinned reference
	last_checked:  string,      // ISO 8601 timestamp
	remote_commit: string,      // Remote commit SHA (short form)
}

// Git reference types for version pinning
GitRefType :: enum {
	Branch,      // Follow branch (default)
	Tag,         // Pinned to specific tag
	Commit,      // Pinned to specific commit
}

// Conflict detection information
ConflictInfo :: struct {
	env_vars:            [dynamic]string,  // Environment variables this plugin sets
	functions:           [dynamic]string,  // Functions this plugin defines
	aliases_:            [dynamic]string,  // Aliases this plugin creates
	detected:            bool,             // Whether conflicts were detected
	conflicting_plugins: [dynamic]string,  // Names of plugins with conflicts
}

// Enhanced plugin configuration (JSON5 format)
PluginConfigJSON :: struct {
	version:      string,
	last_updated: string,  // ISO 8601 timestamp
	plugins:      [dynamic]PluginMetadata,
}

// PluginEntry pairs a short lookup key with its PluginInfo and a category tag.
// Using a fixed-size array of structs instead of a map avoids the
// #+feature dynamic-literals requirement and the permanent heap allocation
// that a global map[string]PluginInfo would incur.
PluginEntry :: struct {
	key:      string,
	category: string,
	info:     PluginInfo,
}

// Popular plugins registry — compile-time constant, zero heap allocation.
// Organized by category: syntax, completion, navigation, git, history,
// prompt, productivity, tools, and utility.
//
// Only real shell plugins belong here: each repo must have a file the loader
// picks up (get_plugin_files_to_source) for its `shell` — otherwise
// `plugin add` refuses it. Binary tools (starship, zoxide, fzf, direnv, …)
// whose repos are sources, not shell code, are not listed. Names must be
// unique (they are the install directory); a unit test checks names and
// URLs (https://github.com/<owner>/<repo>.git).
POPULAR_PLUGINS := [?]PluginEntry{

	// ── Syntax & Colors ──────────────────────────────────────────────────
	{"syntax-highlighting", "syntax", {
		name        = "zsh-syntax-highlighting",
		url         = "https://github.com/zsh-users/zsh-syntax-highlighting.git",
		shell       = .ZSH,
		description = "Fish-like syntax highlighting for ZSH",
	}},
	{"fast-syntax-highlighting", "syntax", {
		name        = "fast-syntax-highlighting",
		url         = "https://github.com/zdharma-continuum/fast-syntax-highlighting.git",
		shell       = .ZSH,
		description = "Feature-rich alternative syntax highlighting for ZSH",
	}},
	{"colored-man-pages", "syntax", {
		name        = "zsh-colored-man-pages",
		url         = "https://github.com/ael-code/zsh-colored-man-pages.git",
		shell       = .ZSH,
		description = "Colorize man pages with ANSI colors",
	}},

	// ── Completion ───────────────────────────────────────────────────────
	{"autosuggestions", "completion", {
		name        = "zsh-autosuggestions",
		url         = "https://github.com/zsh-users/zsh-autosuggestions.git",
		shell       = .ZSH,
		description = "Fish-like autosuggestions based on command history",
	}},
	{"completions", "completion", {
		name        = "zsh-completions",
		url         = "https://github.com/zsh-users/zsh-completions.git",
		shell       = .ZSH,
		description = "Additional completion definitions for ZSH",
	}},
	{"fzf-tab", "completion", {
		name        = "fzf-tab",
		url         = "https://github.com/Aloxaf/fzf-tab.git",
		shell       = .ZSH,
		description = "Replace ZSH default completion with fzf",
	}},
	{"zsh-better-npm-completion", "completion", {
		name        = "zsh-better-npm-completion",
		url         = "https://github.com/lukechilds/zsh-better-npm-completion.git",
		shell       = .ZSH,
		description = "Better npm completion for ZSH",
	}},

	// ── Navigation ───────────────────────────────────────────────────────
	{"z", "navigation", {
		name        = "z",
		url         = "https://github.com/rupa/z.git",
		shell       = .BOTH,
		description = "Jump to frecent directories",
	}},
	{"zsh-interactive-cd", "navigation", {
		name        = "zsh-interactive-cd",
		url         = "https://github.com/changyuheng/zsh-interactive-cd.git",
		shell       = .ZSH,
		description = "Fish-like interactive tab completion for cd",
	}},

	// ── Git ──────────────────────────────────────────────────────────────
	{"git-open", "git", {
		name        = "git-open",
		url         = "https://github.com/paulirish/git-open.git",
		shell       = .BOTH,
		description = "Open the current repo in your browser",
	}},
	{"forgit", "git", {
		name        = "forgit",
		url         = "https://github.com/wfxr/forgit.git",
		shell       = .BOTH,
		description = "Interactive git commands using fzf",
	}},

	// ── History ──────────────────────────────────────────────────────────
	{"history-substring-search", "history", {
		name        = "zsh-history-substring-search",
		url         = "https://github.com/zsh-users/zsh-history-substring-search.git",
		shell       = .ZSH,
		description = "Fish-like history search: type then press Up to filter",
	}},

	// ── Prompt ───────────────────────────────────────────────────────────
	{"powerlevel10k", "prompt", {
		name        = "powerlevel10k",
		url         = "https://github.com/romkatv/powerlevel10k.git",
		shell       = .ZSH,
		description = "Fast and flexible ZSH prompt theme",
	}},
	{"pure", "prompt", {
		name        = "pure",
		url         = "https://github.com/sindresorhus/pure.git",
		shell       = .ZSH,
		description = "Minimal, fast, and pretty ZSH prompt",
	}},
	{"spaceship-prompt", "prompt", {
		name        = "spaceship-prompt",
		url         = "https://github.com/spaceship-prompt/spaceship-prompt.git",
		shell       = .ZSH,
		description = "Astronaut-themed ZSH prompt with git, node, and more",
	}},

	// ── Productivity ─────────────────────────────────────────────────────
	{"you-should-use", "productivity", {
		name        = "zsh-you-should-use",
		url         = "https://github.com/MichaelAquilina/zsh-you-should-use.git",
		shell       = .ZSH,
		description = "Reminds you to use your existing aliases",
	}},
	{"zsh-abbr", "productivity", {
		name        = "zsh-abbr",
		url         = "https://github.com/olets/zsh-abbr.git",
		shell       = .ZSH,
		description = "Fish-like abbreviations that expand on space",
	}},
	{"zsh-autopair", "productivity", {
		name        = "zsh-autopair",
		url         = "https://github.com/hlissner/zsh-autopair.git",
		shell       = .ZSH,
		description = "Auto-close and delete matching delimiters",
	}},
	{"zsh-vi-mode", "productivity", {
		name        = "zsh-vi-mode",
		url         = "https://github.com/jeffreytse/zsh-vi-mode.git",
		shell       = .ZSH,
		description = "Better vi mode for ZSH with text objects",
	}},
	{"zsh-fzf-history-search", "productivity", {
		name        = "zsh-fzf-history-search",
		url         = "https://github.com/joshskidmore/zsh-fzf-history-search.git",
		shell       = .ZSH,
		description = "Use fzf for interactive history search (Ctrl+R)",
	}},
	{"zsh-command-time", "productivity", {
		name        = "zsh-command-time",
		url         = "https://github.com/popstas/zsh-command-time.git",
		shell       = .ZSH,
		description = "Print execution time for long-running commands",
	}},
	{"zsh-notify", "productivity", {
		name        = "zsh-notify",
		url         = "https://github.com/marzocchi/zsh-notify.git",
		shell       = .ZSH,
		description = "Desktop notifications for long-running commands",
	}},

	// ── Version Managers / Tools ─────────────────────────────────────────
	{"nvm", "tools", {
		name        = "zsh-nvm",
		url         = "https://github.com/lukechilds/zsh-nvm.git",
		shell       = .ZSH,
		description = "ZSH plugin for installing and loading nvm",
	}},
	{"docker-zsh-completion", "tools", {
		name        = "docker-zsh-completion",
		url         = "https://github.com/greymd/docker-zsh-completion.git",
		shell       = .ZSH,
		description = "ZSH completion for Docker",
	}},
	{"kubectl-zsh-completion", "tools", {
		name        = "kubectl-zsh-completion",
		url         = "https://github.com/nnao45/zsh-kubectl-completion.git",
		shell       = .ZSH,
		description = "ZSH completion for kubectl",
	}},

	// ── Utility ──────────────────────────────────────────────────────────
	{"zsh-safe-rm", "utility", {
		name        = "zsh-safe-rm",
		url         = "https://github.com/mattmc3/zsh-safe-rm.git",
		shell       = .ZSH,
		description = "Use trash instead of rm to prevent accidental deletion",
	}},
	{"zsh-bd", "utility", {
		name        = "zsh-bd",
		url         = "https://github.com/Tarrasch/zsh-bd.git",
		shell       = .ZSH,
		description = "Jump back to a specific directory in your history",
	}},
	{"zsh-titles", "utility", {
		name        = "zsh-titles",
		url         = "https://github.com/jreese/zsh-titles.git",
		shell       = .ZSH,
		description = "Automatic terminal and tmux title management",
	}},
	{"zsh-256color", "utility", {
		name        = "zsh-256color",
		url         = "https://github.com/chrissicool/zsh-256color.git",
		shell       = .ZSH,
		description = "Enable 256 color support in ZSH",
	}},
	{"zsh-ssh-agent", "utility", {
		name        = "zsh-ssh-agent",
		url         = "https://github.com/bobsoppe/zsh-ssh-agent.git",
		shell       = .ZSH,
		description = "Persistent ssh-agent with keychain integration",
	}},
	{"zsh-gpg-agent", "utility", {
		name        = "zsh-gpg-agent",
		url         = "https://github.com/axtl/gpg-agent.zsh.git",
		shell       = .ZSH,
		description = "Manage GPG agent for signing and encryption",
	}},
	{"zsh-thefuck", "utility", {
		name        = "zsh-thefuck",
		url         = "https://github.com/laggardkernel/zsh-thefuck.git",
		shell       = .ZSH,
		description = "Lazy load thefuck with ZSH integration",
	}},

	// ── Fish-native ──────────────────────────────────────────────────────
	{"z-fish", "navigation", {
		name        = "z.fish",
		url         = "https://github.com/jethrokuan/z.git",
		shell       = .FISH,
		description = "Fish port of rupa's z — jump to frecent directories",
	}},
	{"pure-fish", "prompt", {
		name        = "pure-fish",
		url         = "https://github.com/pure-fish/pure.git",
		shell       = .FISH,
		description = "Minimal, fast prompt for fish (port of sindresorhus/pure)",
	}},
	{"tide", "prompt", {
		name        = "tide",
		url         = "https://github.com/IlanCosman/tide.git",
		shell       = .FISH,
		description = "Ultimate minimal, fast, feature-rich fish prompt",
	}},
	{"bass", "utility", {
		name        = "bass",
		url         = "https://github.com/edc/bass.git",
		shell       = .FISH,
		description = "Make bash utilities usable in fish (runs bash scripts)",
	}},
	{"nvm-fish", "tools", {
		name        = "nvm.fish",
		url         = "https://github.com/jorgebucaran/nvm.fish.git",
		shell       = .FISH,
		description = "Node.js version manager for fish, written in fish",
	}},
	{"fzf-fish", "utility", {
		name        = "fzf.fish",
		url         = "https://github.com/PatrickF1/fzf.fish.git",
		shell       = .FISH,
		description = "Ergonomic fzf keybindings for fish (Ctrl-F variants)",
	}},
	{"autopair-fish", "productivity", {
		name        = "autopair.fish",
		url         = "https://github.com/jorgebucaran/autopair.fish.git",
		shell       = .FISH,
		description = "Auto-close and delete paired symbols in fish",
	}},
	{"done", "productivity", {
		name        = "done",
		url         = "https://github.com/franciscolourenco/done.git",
		shell       = .FISH,
		description = "Notify when long-running commands complete in fish",
	}},
}

// popular_plugin_find does a linear scan of POPULAR_PLUGINS by key.
// Returns (info, true) on match, (zero, false) otherwise.
// O(n) over a few dozen entries — no hash overhead, no heap allocation.
popular_plugin_find :: proc(key: string) -> (PluginInfo, bool) {
	for entry in POPULAR_PLUGINS {
		if entry.key == key {
			return entry.info, true
		}
	}
	return PluginInfo{}, false
}

// Parse shell compatibility from string
parse_shell_compat :: proc(shell_str: string) -> ShellCompat {
	shell_lower := strings.to_lower(shell_str)
	defer delete(shell_lower)

	switch shell_lower {
	case "zsh":
		return .ZSH
	case "bash":
		return .BASH
	case "both":
		return .BOTH
	case "fish":
		return .FISH
	case "any", "all":
		return .ANY
	}
	return .BOTH
}

// Convert shell compatibility to string
shell_compat_to_string :: proc(compat: ShellCompat) -> string {
	switch compat {
	case .ZSH:
		return "zsh"
	case .BASH:
		return "bash"
	case .BOTH:
		return "both"
	case .FISH:
		return "fish"
	case .ANY:
		return "any"
	}
	return "both"
}

// Helper: Get current timestamp in ISO 8601 format
get_iso8601_timestamp :: proc() -> string {
	now := time.now()
	year, month, day := time.date(now)
	hour, minute, second := time.clock(now)
	return fmt.aprintf("%d-%02d-%02dT%02d:%02d:%02dZ",
		year, month, day, hour, minute, second)
}

// Get git information for an installed plugin
get_git_info :: proc(plugin_dir: string) -> GitMetadata {
	info := GitMetadata{}

	if !os.exists(plugin_dir) {
		return info
	}

	// Get current branch — no shell, args passed directly to git
	info.branch = capture_command([]string{"git", "-C", plugin_dir, "rev-parse", "--abbrev-ref", "HEAD"})

	// Get local commit (short SHA)
	info.commit = capture_command([]string{"git", "-C", plugin_dir, "rev-parse", "--short", "HEAD"})

	// Remote commit will be fetched during check/update
	// IMPORTANT: Must be a separate allocation (cleanup_plugin_metadata deletes both independently)
	info.remote_commit = strings.clone(info.commit)
	info.last_checked = get_iso8601_timestamp()

	return info
}

// Cleanup helper for PluginMetadata
cleanup_plugin_metadata :: proc(plugin: ^PluginMetadata) {
	delete(plugin.name)
	delete(plugin.display_name)
	delete(plugin.url)
	delete(plugin.installed_path)
	delete(plugin.entry_file)
	delete(plugin.git.branch)
	delete(plugin.git.tag)
	delete(plugin.git.commit)
	delete(plugin.git.pinned_ref)
	delete(plugin.git.last_checked)
	delete(plugin.git.remote_commit)
	for d in plugin.dependencies {
		delete(d)
	}
	delete(plugin.dependencies)
	for u in plugin.use {
		delete(u)
	}
	delete(plugin.use)
	for p in plugin.profiles {
		delete(p)
	}
	delete(plugin.profiles)
	for ev in plugin.conflicts.env_vars {
		delete(ev)
	}
	delete(plugin.conflicts.env_vars)
	for fn in plugin.conflicts.functions {
		delete(fn)
	}
	delete(plugin.conflicts.functions)
	for al in plugin.conflicts.aliases_ {
		delete(al)
	}
	delete(plugin.conflicts.aliases_)
	for cp in plugin.conflicts.conflicting_plugins {
		delete(cp)
	}
	delete(plugin.conflicts.conflicting_plugins)
}

// Cleanup helper for PluginConfigJSON
cleanup_plugin_config_json :: proc(config: ^PluginConfigJSON) {
	delete(config.version)
	delete(config.last_updated)
	for &plugin in config.plugins {
		cleanup_plugin_metadata(&plugin)
	}
	delete(config.plugins)
}


// Handle plugin command routing
handle_plugin_command :: proc(action: Action, args: []string) {
	#partial switch action {
	case .ADD:
		handle_plugin_add(args)
	case .REMOVE:
		handle_plugin_remove(args)
	case .LIST:
		handle_plugin_list(args)
	case .GET:
		handle_plugin_get(args)
	case .CHECK:
		handle_plugin_check(args)
	case .UPDATE:
		handle_plugin_update(args)
	case .ENABLE:
		handle_plugin_enable(args)
	case .DISABLE:
		handle_plugin_disable(args)
	case .PRIORITY:
		handle_plugin_priority(args)
	case .SEARCH:
		handle_plugin_search(args)
	case .HELP:
		print_plugin_help()
	case:
		print_error_simple("Unknown plugin action")
		print_plugin_help()
		os.exit(EXIT_USAGE)
	}
}

// ============================================================================
// Help text (from plugin_help.odin)
// ============================================================================

print_plugin_help :: proc() {
	fmt.printf("\n%s%swayu plugin - Plugin management%s\n\n", BOLD, get_primary(), RESET)
	fmt.printf("%s%sUSAGE:%s\n", BOLD, get_secondary(), RESET)
	fmt.println("  wayu plugin <action> [arguments]")
	fmt.printf("\n%s%sACTIONS:%s\n", BOLD, get_secondary(), RESET)
	fmt.println("  add <name-or-url>       Install plugin (--use <glob>: files to load;")
	fmt.println("                          see 'wayu plugin add help')")
	fmt.println("  remove <name> --yes     Remove plugin (alias: rm)")
	fmt.println("  list                    List installed plugins")
	fmt.println("  enable <name>           Enable disabled plugin")
	fmt.println("  disable <name>          Disable plugin without removing")
	fmt.println("  priority <name> <num>   Set plugin load priority (lower = earlier)")
	fmt.println("  get <name>              Show plugin info and copy URL to clipboard")
	fmt.println("  check                   Check all plugins for updates")
	fmt.println("  update <name|--all>     Update specific plugin or all plugins")
	fmt.println("  search [query]          Browse popular plugins (filter by optional query)")
	fmt.println("  help                    Show this help message")
	fmt.println()
	fmt.println("  <name> must match an installed plugin exactly; on a miss, similar")
	fmt.println("  names are listed on stderr and the command exits 65.")
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
	fmt.printf("  %s# Load a specific file of the repository%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin add https://github.com/user/theme.git --use 'theme.zsh'%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Remove a plugin%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin remove syntax-highlighting --yes%s\n", get_muted(), RESET)
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
	fmt.printf("  %s# Browse all popular plugins%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin search%s\n", get_muted(), RESET)
	fmt.println()
	fmt.printf("  %s# Search popular plugins by keyword%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin search syntax%s\n", get_muted(), RESET)
	fmt.printf("\n%s%sPOPULAR PLUGINS:%s\n", BOLD, get_secondary(), RESET)
	count := 0
	for entry in POPULAR_PLUGINS {
		if count >= 5 { break }
		fmt.printf("  %s• %s - %s%s\n", get_muted(), entry.key, entry.info.description, RESET)
		count += 1
	}
	fmt.println()
}

print_plugin_add_help :: proc() {
	fmt.printf("\n%s%swayu plugin add - Install plugin%s\n\n", BOLD, get_primary(), RESET)
	fmt.printf("%s%sUSAGE:%s\n", BOLD, get_secondary(), RESET)
	fmt.println("  wayu plugin add <name-or-url>[@<commit>]")
	fmt.println()
	fmt.println("  URLs must use https://, ssh://, git@host: or file:// (http:// is refused).")
	fmt.println("  Appending @<commit> (7-40 hex digits) pins the plugin to that commit;")
	fmt.println("  pinned plugins are skipped by 'plugin update' and verified by 'plugin check'.")
	fmt.println()
	fmt.println("  Without --use, wayu loads the first of <name>.plugin.<ext>, <name>.<ext>,")
	fmt.println("  <name>-init.<ext>, init.<ext>, plugin.<ext> (zsh: <name>.zsh-theme;")
	fmt.println("  zsh/bash: <name>.plugin.sh, <name>.sh) at the repository root, else every")
	fmt.println("  top-level *.<ext> (zsh: else *.zsh-theme); fish also loads conf.d/*.fish and")
	fmt.println("  functions/*.fish. A plugin with nothing to load is not installed.")
	fmt.printf("\n%s%sOPTIONS:%s\n", BOLD, get_secondary(), RESET)
	fmt.println("  --use <glob>   File(s) at the repository root to load instead (repeatable)")
	fmt.printf("\n%s%sEXAMPLES:%s\n", BOLD, get_secondary(), RESET)
	fmt.printf("  %swayu plugin add syntax-highlighting%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin add https://github.com/user/plugin.git%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin add https://github.com/user/plugin.git@1a2b3c4%s\n", get_muted(), RESET)
	fmt.printf("  %swayu plugin add https://github.com/user/theme.git --use 'theme.zsh'%s\n", get_muted(), RESET)
	fmt.println()
}

// Explain (stderr) why `plugin add` refused a checkout with nothing to load.
print_plugin_nothing_to_load :: proc(info: PluginInfo, use_globs: []string) {
	if len(use_globs) > 0 {
		print_error_simple("Plugin '%s' not installed: --use %s matches no file at the repository root",
			info.name, strings.join(use_globs, " ", context.temp_allocator))
		return
	}
	print_error_simple("Plugin '%s' not installed: it has nothing wayu can load for %s",
		info.name, shell_compat_to_string(info.shell))
	fmt.eprintfln("  Looked for %s.plugin.<ext>, %s.<ext>, init.<ext>, *.<ext> and *.zsh-theme at the", info.name, info.name)
	fmt.eprintln("  repository root (fish: also conf.d/*.fish, functions/*.fish).")
	fmt.eprintln("  If it ships its shell code under another name, name it with --use:")
	fmt.eprintfln("    wayu plugin add %s --use '<file-or-glob>'", info.url)
	fmt.eprintln("  Tools installed as binaries (e.g. starship, zoxide, direnv) are not plugins:")
	fmt.eprintln("  install them with your package manager and load them from wayu.toml [tools],")
	fmt.eprintln("  e.g.  zoxide = { kind = \"evalcache\", args = \"init zsh\" }")
}
