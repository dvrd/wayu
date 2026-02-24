package wayu

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// Shell compatibility for plugins
ShellCompat :: enum {
	ZSH,
	BASH,
	BOTH,
}

// Plugin information from registry
PluginInfo :: struct {
	name:        string,
	url:         string,
	shell:       ShellCompat,
	description: string,
}

// Installed plugin with metadata
InstalledPlugin :: struct {
	name:           string,
	url:            string,
	enabled:        bool,
	shell:          ShellCompat,
	installed_path: string,
	entry_file:     string, // Main file to source
}

// Plugin configuration state
PluginConfig :: struct {
	plugins: [dynamic]InstalledPlugin,
}

// Enhanced plugin metadata with git tracking, dependencies, and conflicts (JSON5 format)
PluginMetadata :: struct {
	name:           string,
	url:            string,
	enabled:        bool,
	shell:          ShellCompat,
	installed_path: string,
	entry_file:     string,
	git:            GitMetadata,
	dependencies:   [dynamic]string,
	priority:       int,
	config:         map[string]string,
	conflicts:      ConflictInfo,
}

// Git metadata for update tracking
GitMetadata :: struct {
	branch:        string,  // Current branch (default: "master" or "main")
	commit:        string,  // Local commit SHA (short form)
	last_checked:  string,  // ISO 8601 timestamp of last update check
	remote_commit: string,  // Remote commit SHA (short form)
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
POPULAR_PLUGINS := [54]PluginEntry{

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
	{"zoxide", "navigation", {
		name        = "zoxide",
		url         = "https://github.com/ajeetdsouza/zoxide.git",
		shell       = .BOTH,
		description = "Smarter cd command with learning and fzf integration",
	}},
	{"autojump", "navigation", {
		name        = "autojump",
		url         = "https://github.com/wting/autojump.git",
		shell       = .BOTH,
		description = "A cd command that learns your habits",
	}},
	{"fasd", "navigation", {
		name        = "fasd",
		url         = "https://github.com/clvv/fasd.git",
		shell       = .BOTH,
		description = "Quick access to files and directories by frecency",
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
	{"git-extras", "git", {
		name        = "git-extras",
		url         = "https://github.com/tj/git-extras.git",
		shell       = .BOTH,
		description = "Extra git commands: summary, changelog, effort, and more",
	}},
	{"git-flow", "git", {
		name        = "gitflow-avh",
		url         = "https://github.com/petervanderdoes/gitflow-avh.git",
		shell       = .BOTH,
		description = "Git extensions for the git-flow branching model",
	}},
	{"delta", "git", {
		name        = "delta",
		url         = "https://github.com/dandavison/delta.git",
		shell       = .BOTH,
		description = "Syntax-highlighting pager for git diff output",
	}},

	// ── History ──────────────────────────────────────────────────────────
	{"history-substring-search", "history", {
		name        = "zsh-history-substring-search",
		url         = "https://github.com/zsh-users/zsh-history-substring-search.git",
		shell       = .ZSH,
		description = "Fish-like history search: type then press Up to filter",
	}},
	{"atuin", "history", {
		name        = "atuin",
		url         = "https://github.com/atuinsh/atuin.git",
		shell       = .BOTH,
		description = "Magical shell history with sync and statistics",
	}},
	{"zsh-history-enquirer", "history", {
		name        = "zsh-history-enquirer",
		url         = "https://github.com/popstas/zsh-command-time.git",
		shell       = .ZSH,
		description = "Show elapsed time for long-running commands",
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
	{"starship", "prompt", {
		name        = "starship",
		url         = "https://github.com/starship/starship.git",
		shell       = .BOTH,
		description = "Cross-shell minimal and fast prompt",
	}},
	{"spaceship-prompt", "prompt", {
		name        = "spaceship-prompt",
		url         = "https://github.com/spaceship-prompt/spaceship-prompt.git",
		shell       = .ZSH,
		description = "Astronaut-themed ZSH prompt with git, node, and more",
	}},
	{"oh-my-posh", "prompt", {
		name        = "oh-my-posh",
		url         = "https://github.com/JanDeDobbeleer/oh-my-posh.git",
		shell       = .BOTH,
		description = "A prompt theme engine for any shell",
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
	{"asdf", "tools", {
		name        = "asdf-vm",
		url         = "https://github.com/asdf-vm/asdf.git",
		shell       = .BOTH,
		description = "Manage multiple runtime versions with one tool",
	}},
	{"mise", "tools", {
		name        = "mise",
		url         = "https://github.com/jdx/mise.git",
		shell       = .BOTH,
		description = "Fast polyglot runtime manager (asdf-compatible)",
	}},
	{"pyenv", "tools", {
		name        = "pyenv",
		url         = "https://github.com/pyenv/pyenv.git",
		shell       = .BOTH,
		description = "Simple Python version management",
	}},
	{"rbenv", "tools", {
		name        = "rbenv",
		url         = "https://github.com/rbenv/rbenv.git",
		shell       = .BOTH,
		description = "Manage multiple Ruby versions",
	}},
	{"rustup", "tools", {
		name        = "rustup",
		url         = "https://github.com/rust-lang/rustup.git",
		shell       = .BOTH,
		description = "The Rust toolchain installer and version manager",
	}},
	{"volta", "tools", {
		name        = "volta",
		url         = "https://github.com/volta-cli/volta.git",
		shell       = .BOTH,
		description = "Hassle-free JavaScript tool manager",
	}},
	{"direnv", "tools", {
		name        = "direnv",
		url         = "https://github.com/direnv/direnv.git",
		shell       = .BOTH,
		description = "Load and unload env vars based on current directory",
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
	{"zsh-dotenv", "utility", {
		name        = "zsh-dotenv",
		url         = "https://github.com/ohmyzsh/ohmyzsh/tree/master/plugins/dotenv",
		shell       = .ZSH,
		description = "Automatically load .env files when entering directories",
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
	{"fzf", "utility", {
		name        = "fzf",
		url         = "https://github.com/junegunn/fzf.git",
		shell       = .BOTH,
		description = "General-purpose fuzzy finder with shell integration",
	}},
	{"ripgrep", "utility", {
		name        = "ripgrep",
		url         = "https://github.com/BurntSushi/ripgrep.git",
		shell       = .BOTH,
		description = "Fast recursive search tool, grep replacement",
	}},
	{"bat", "utility", {
		name        = "bat",
		url         = "https://github.com/sharkdp/bat.git",
		shell       = .BOTH,
		description = "A cat clone with syntax highlighting and git integration",
	}},
	{"eza", "utility", {
		name        = "eza",
		url         = "https://github.com/eza-community/eza.git",
		shell       = .BOTH,
		description = "Modern replacement for ls with colors and icons",
	}},
	{"zsh-thefuck", "utility", {
		name        = "zsh-thefuck",
		url         = "https://github.com/laggardkernel/zsh-thefuck.git",
		shell       = .ZSH,
		description = "Lazy load thefuck with ZSH integration",
	}},
}

// popular_plugin_find does a linear scan of POPULAR_PLUGINS by key.
// Returns (info, true) on match, (zero, false) otherwise.
// O(n) over 9 entries — no hash overhead, no heap allocation.
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
	delete(plugin.url)
	delete(plugin.installed_path)
	delete(plugin.entry_file)
	delete(plugin.git.branch)
	delete(plugin.git.commit)
	delete(plugin.git.last_checked)
	delete(plugin.git.remote_commit)
	delete(plugin.dependencies)
	delete(plugin.config)
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
		os.exit(1)
	}
}
