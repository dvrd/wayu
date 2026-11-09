// highlight.odin - built-in zsh syntax highlighting ([settings] highlight,
// OKAMI-377), in place of the zsh-syntax-highlighting /
// fast-syntax-highlighting plugins.
//
// The zsh code is src/highlight.zsh (embedded at compile time, emitted into
// core.zsh with the style table filled in). It runs in a
// zle-line-pre-redraw hook (add-zle-hook-widget, like wayu's autosuggest),
// so no widget is wrapped and nothing is set up per prompt; nothing forks.
// Words come from zsh's own lexer (${(z)BUFFER}) and are mapped back to
// offsets in BUFFER; command lookups ($aliases, $functions, $builtins,
// $commands, [[ -x ]]) and path checks are cached until a command runs or
// PWD / PATH change, and a keystroke at the end of the line only
// re-highlights the last word or two (per-word state snapshots).
package wayu

import "core:fmt"
import "core:strings"

ZSH_HIGHLIGHT :: #load("highlight.zsh", string)

// A style the highlighter can apply: zsh-syntax-highlighting's main
// highlighter names (so its ZSH_HIGHLIGHT_STYLES values carry over), plus
// `expansion` ($var, ${...}, $((...)) outside double quotes). The default
// is zsh-syntax-highlighting's; "" = none.
HighlightStyle :: struct {
	name:    string,
	default: string,
}

HIGHLIGHT_STYLES :: [?]HighlightStyle{
	{"unknown-token", "fg=red,bold"},
	{"reserved-word", "fg=yellow"},
	{"alias", "fg=green"},
	{"suffix-alias", "fg=green,underline"},
	{"global-alias", "fg=cyan"},
	{"builtin", "fg=green"},
	{"function", "fg=green"},
	{"command", "fg=green"},
	{"precommand", "fg=green,underline"},
	{"commandseparator", ""},
	{"autodirectory", "fg=green,underline"},
	{"path", "underline"},
	{"path_prefix", "underline"},
	{"globbing", "fg=blue"},
	{"expansion", "fg=cyan"},
	{"command-substitution-delimiter", "fg=magenta"},
	{"process-substitution-delimiter", "fg=magenta"},
	{"back-quoted-argument-delimiter", "fg=magenta"},
	{"single-hyphen-option", ""},
	{"double-hyphen-option", ""},
	{"single-quoted-argument", "fg=yellow"},
	{"double-quoted-argument", "fg=yellow"},
	{"dollar-quoted-argument", "fg=yellow"},
	{"dollar-double-quoted-argument", "fg=cyan"},
	{"back-double-quoted-argument", "fg=cyan"},
	{"back-dollar-quoted-argument", "fg=cyan"},
	{"assign", ""},
	{"redirection", "fg=yellow"},
	{"comment", "fg=black,bold"},
}

HIGHLIGHT_STYLE_COUNT :: len(HIGHLIGHT_STYLES)

// Plugins the built-in highlighter replaces: not loaded while it is on
// (marked loaded for plugins.zsh's guard; `wayu doctor` warns).
HIGHLIGHT_PLUGINS :: [?]string{"zsh-syntax-highlighting", "fast-syntax-highlighting"}

// Index of a style name in HIGHLIGHT_STYLES, -1 if unknown.
highlight_style_index :: proc(name: string) -> int {
	styles := HIGHLIGHT_STYLES
	for s, i in styles {
		if s.name == name { return i }
	}
	return -1
}

// A `[settings] highlight_styles` value's problem ("" = fine): a
// region_highlight spec string like autosuggest_style, or "none".
highlight_style_issue :: proc(name: string, v: ^TomlValue) -> string {
	if v != nil && v.type == .STRING && autosuggest_style_valid(v.str_val) { return "" }
	return fmt.tprintf("settings.highlight_styles.%s must be a highlight spec string like \"fg=green,bold\" or \"none\" (one line, at most 64 bytes)", name)
}

// The style table for core.zsh: the defaults, overridden by
// `[settings] highlight_styles` (inline table or [settings.highlight_styles]);
// unknown names and unusable values are skipped (`toml validate` reports
// them). "none" = no highlighting. Strings are temp-allocated or constants.
read_highlight_styles :: proc(doc: ^TomlDoc) -> (out: [HIGHLIGHT_STYLE_COUNT]string) {
	styles := HIGHLIGHT_STYLES
	for s, i in styles { out[i] = s.default }
	v := get_toml_value(doc, "settings.highlight_styles")
	if v == nil || v.type != .TABLE { return }
	for name, val in v.table_val {
		i := highlight_style_index(name)
		if i < 0 || val == nil || val.type != .STRING || !autosuggest_style_valid(val.str_val) { continue }
		out[i] = "" if val.str_val == "none" else strings.clone(val.str_val, context.temp_allocator)
	}
	return
}

// The highlighter module for core.zsh, styles filled in (one
// `name 'spec'` pair per line, shell-quoted).
emit_zsh_highlight :: proc(b: ^strings.Builder, styles: [HIGHLIGHT_STYLE_COUNT]string) {
	table := strings.builder_make(context.temp_allocator)
	defs := HIGHLIGHT_STYLES
	for s, i in defs {
		fmt.sbprintf(&table, "\n      %s %s", s.name, shell_quote(styles[i], .ZSH))
	}
	strings.write_string(&table, "\n    ")
	code, _ := strings.replace_all(ZSH_HIGHLIGHT, "@STYLES@", strings.to_string(table), context.temp_allocator)
	fmt.sbprint(b, code)
}
