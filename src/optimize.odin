// optimize.odin - `wayu optimize`: absorb rc-file lines into wayu
//
// Installers append lines to the shell's startup files after the line that
// loads wayu: `source <(tool completion zsh)` (forks the tool at every
// start), `fpath=(dir $fpath)` + a second `compinit` (a full completion
// rebuild), `export PATH=dir:$PATH`, aliases and exports. `wayu optimize`
// moves the lines it can prove equivalent into wayu and removes them from
// the rc file (backup first, `wayu backup restore` undoes it):
//
//   source <(cmd args) / . <(cmd args) / eval "$(cmd args)"  (zsh, bash)
//   cmd args | source                                        (fish)
//       -> entries.json `generators`: core runs `_wayu_evalcache cmd args`
//          (output cached, re-run when the binary changes). Only from the
//          interactive rc file (.zshrc / .bashrc; fish: every config file),
//          only when the args name an init/completion/hook/shellenv/activate
//          subcommand, and emitted in interactive shells only (zsh/bash).
//   fpath=(dir $fpath) / fpath+=(dir) / FPATH=dir:$FPATH        (zsh)
//       -> entries.json `fpath` (put on fpath before wayu's compinit)
//   compinit / autoload -Uz compinit [&& compinit -C ...]       (zsh)
//       -> removed: wayu already runs compinit (it was a second rebuild)
//   export PATH=dir:$PATH / PATH="$PATH:dir" / path=(dir $path)
//   set -gx PATH dir $PATH / fish_add_path dir                  (fish)
//       -> PATH entries (prepends in front of the wayu list in the order the
//          shell would end up with; appends at its end - wayu prepends them)
//   alias name=value / alias name value                         (fish)
//       -> aliases (value must have no expansion)
//   export NAME=value / set -gx NAME value                      (fish)
//       -> constants; a secret-looking name/value is stored encrypted
//          (`const add --secret` semantics)
//
// Only lines AFTER the line that loads wayu are considered (files in load
// order), and only top-level statements: anything inside if/for/while/case/
// function bodies, multi-line or compound statements, values with command
// substitution / globs / variables wayu can't resolve stays untouched.
//
// The classifier (rc_classify_line / rc_scan_content) is pure; the command
// handler, the prompt-hook notice (`--notify`), `[settings] auto_optimize`
// and the doctor check are below it.

package wayu

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// ============================================================================
// Classifier (pure)
// ============================================================================

RcKind :: enum {
	KEEP,
	GENERATOR,
	FPATH,
	COMPINIT,
	PATH,
	ALIAS,
	ENV,
}

// One classified statement. Strings are temp-allocated. Values (dirs, env
// values) are in wayu's stored form: `$NAME` expands, a leading `~` is
// written as `$HOME`.
RcClass :: struct {
	kind:    RcKind,
	cmd:     string, // GENERATOR: the command (a bare name on PATH)
	args:    string, // GENERATOR: its args, [tools] args syntax
	argv:    []string, // GENERATOR: cmd + args as words (doctor times it)
	prepend: []string, // PATH / FPATH: dirs put in front (left to right)
	appends: []string, // PATH / FPATH: dirs put at the end
	name:    string, // ALIAS / ENV
	value:   string, // ALIAS / ENV
	secret:  bool, // ENV: looks secret -> stored encrypted
	reason:  string, // KEEP: why it stays (static or temp)
}

// What the classifier may assume about where a statement is.
RcContext :: struct {
	shell:       ShellType,
	// The interactive rc file (.zshrc / .bashrc; every fish config file):
	// generator lines are only moved from there.
	interactive: bool,
	// Variables a moved value may reference: always HOME/USER/LOGNAME, plus
	// constants wayu already exports and ones moved earlier in the scan.
	known_vars:  []string,
}

// Subcommand words that mark a generator whose output is static shell code
// (safe to cache): `zoxide init zsh`, `kubectl completion zsh`,
// `conda shell.zsh hook`, `brew shellenv`, `mise activate zsh`.
RC_GENERATOR_WORDS :: []string {
	"init",
	"completion",
	"completions",
	"hook",
	"shellenv",
	"activate",
	"virtualenv-init",
}

// Env names never moved: wayu's own location/state, the shell's own
// variables, and the list-valued ones handled as PATH/FPATH.
RC_ENV_DENY :: []string {
	"PATH",
	"FPATH",
	"MANPATH",
	"HOME",
	"SHELL",
	"ZDOTDIR",
	"PWD",
	"OLDPWD",
	"SHLVL",
	"IFS",
	"PS1",
	"PS2",
	"PS3",
	"PS4",
	"PROMPT",
	"RPROMPT",
	"RPS1",
	"PROMPT_COMMAND",
	"XDG_DATA_HOME",
	"XDG_CONFIG_HOME",
	"XDG_CACHE_HOME",
	"XDG_STATE_HOME",
	"XDG_RUNTIME_DIR",
	"HISTFILE",
	"fish_user_paths",
	"fish_complete_path",
	"fish_function_path",
}

RC_BASE_VARS :: []string{"HOME", "USER", "LOGNAME"}

@(private = "file")
rc_keep :: proc(reason: string) -> RcClass {
	return RcClass{kind = .KEEP, reason = reason}
}

// Classify one line (or a `\`-continued statement) on its own. For tests and
// callers holding a single statement; rc files go through rc_scan_content.
rc_classify_line :: proc(line: string, ctx: RcContext) -> RcClass {
	context.allocator = context.temp_allocator
	stmts := shell_parse_statements(line, .FISH if ctx.shell == .FISH else .POSIX)
	if len(stmts) == 0 {
		return rc_keep("blank or comment")
	}
	if len(stmts) > 1 {
		return rc_keep("several statements")
	}
	if len(stmts[0].error) > 0 {
		return rc_keep(stmts[0].error)
	}
	return rc_classify_statement(stmts[0].tokens[:], line, ctx)
}

// Classify the tokens of one top-level statement. `raw` is its source text.
rc_classify_statement :: proc(toks: []ShellToken, raw: string, ctx: RcContext) -> RcClass {
	context.allocator = context.temp_allocator
	if len(toks) == 0 || toks[0].kind != .Word {
		return rc_keep("not a simple command")
	}
	first := toks[0].word.text
	if rc_loads_wayu(raw) {
		return rc_keep("loads wayu")
	}

	if ctx.shell == .FISH {
		switch first {
		case "alias":
			return rc_classify_alias(toks, ctx)
		case "set":
			return rc_classify_fish_set(toks, ctx)
		case "fish_add_path":
			return rc_classify_fish_add_path(toks, ctx)
		}
		return rc_classify_fish_generator(toks, ctx)
	}

	switch first {
	case "source", ".", "eval":
		return rc_classify_generator(toks, raw, ctx)
	case "alias":
		return rc_classify_alias(toks, ctx)
	case "export":
		if len(toks) == 2 && toks[1].kind == .Word {
			w := toks[1].word
			eq := strings.index_byte(w.text, '=')
			if eq <= 0 {
				return rc_keep("export without a value")
			}
			name := w.text[:eq]
			if name == "PATH" || (name == "FPATH" && ctx.shell == .ZSH) {
				return rc_classify_colon_list(name, w.text[eq + 1:], w.active[eq + 1:], ctx)
			}
			return rc_classify_env(name, w.text[eq + 1:], w.active[eq + 1:], ctx)
		}
		return rc_keep("export of several names or with options")
	case "autoload", "compinit":
		if ctx.shell == .ZSH {
			return rc_classify_compinit(toks)
		}
		return rc_keep("not a zsh rc file")
	}

	// Assignments: PATH=..., path=(...), fpath+=(...).
	eq := strings.index_byte(first, '=')
	if eq > 0 {
		lhs := first[:eq]
		appending := strings.has_suffix(lhs, "+")
		if appending {
			lhs = lhs[:len(lhs) - 1]
		}
		switch {
		case (lhs == "PATH" || (lhs == "FPATH" && ctx.shell == .ZSH)) && !appending:
			if len(toks) != 1 {
				return rc_keep("not a single assignment")
			}
			return rc_classify_colon_list(lhs, first[eq + 1:], toks[0].word.active[eq + 1:], ctx)
		case (lhs == "path" || lhs == "fpath") && ctx.shell == .ZSH:
			return rc_classify_zsh_array(lhs, appending, first[eq + 1:], toks, ctx)
		}
	}
	return rc_keep("not a recognised pattern")
}

// Is the word fully literal (no expansion of any kind would happen)?
@(private = "file")
rc_word_literal :: proc(w: ShellWord) -> bool {
	for c, i in transmute([]byte)w.text {
		if !w.active[i] {
			continue
		}
		switch c {
		case '$', '`', '*', '?', '[', ']', '~', '{', '}', '\\', '!':
			return false
		}
	}
	return true
}

// Can the generator word be written bare in [tools] args?
@(private = "file")
rc_bare_arg :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for c in transmute([]byte)s {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		case c == '-' ||
		     c == '_' ||
		     c == '.' ||
		     c == '/' ||
		     c == ',' ||
		     c == ':' ||
		     c == '+' ||
		     c == '@' ||
		     c == '%' ||
		     c == '=':
		case:
			return false
		}
	}
	return true
}

// cmd + args from the words of a generator command (`ng completion script`),
// or ok=false with a reason. A trailing `2>/dev/null` is dropped (the
// evalcache discards stderr too).
@(private = "file")
rc_generator_from_tokens :: proc(
	inner: []ShellToken,
	ctx: RcContext,
) -> (
	cmd, args: string,
	argv: []string,
	reason: string,
	ok: bool,
) {
	toks := inner
	n := len(toks)
	if n >= 3 &&
	   toks[n - 3].kind == .Word &&
	   toks[n - 3].word.text == "2" &&
	   toks[n - 2].kind == .Op &&
	   toks[n - 2].op == ">" &&
	   toks[n - 1].kind == .Word &&
	   toks[n - 1].word.text == "/dev/null" {
		toks = toks[:n - 3]
	}
	if len(toks) == 0 {
		reason = "empty command"; return
	}
	words := make([dynamic]string, context.temp_allocator)
	for t in toks {
		if t.kind != .Word {
			reason = "the command uses shell operators"; return
		}
		if !rc_word_literal(t.word) {
			reason = "the command has expansions"; return
		}
		append(&words, t.word.text)
	}
	if !is_safe_alias_name(words[0]) ||
	   strings.contains_rune(words[0], '/') ||
	   words[0] == "wayu" {
		reason = "the command is not a plain name on PATH"
		return
	}
	if len(words) < 2 {
		reason = "no init/completion subcommand"; return
	}
	marked := false
	for w in words[1:] {
		for g in RC_GENERATOR_WORDS {
			if w == g || strings.has_suffix(w, fmt.tprintf("-%s", g)) {
				marked = true
			}
		}
	}
	if !marked {
		reason = "output may change between runs (no init/completion/hook subcommand)"; return
	}
	b := strings.builder_make(context.temp_allocator)
	for w, i in words[1:] {
		if i > 0 {
			strings.write_byte(&b, ' ')
		}
		if rc_bare_arg(w) {
			strings.write_string(&b, w)
		} else {
			strings.write_string(&b, shell_single_quote(w, context.temp_allocator))
		}
	}
	if _, r, valid := tool_args_to_shell(strings.to_string(b), context.temp_allocator); !valid {
		reason = r
		return
	}
	return words[0], strings.to_string(b), words[:], "", true
}

// source <(cmd args) / . <(cmd args) / eval "$(cmd args)"
@(private = "file")
rc_classify_generator :: proc(toks: []ShellToken, raw: string, ctx: RcContext) -> RcClass {
	inner: []ShellToken
	first := toks[0].word.text
	if first == "eval" {
		if len(toks) != 2 || toks[1].kind != .Word {
			return rc_keep("eval of several words")
		}
		w := toks[1].word.text
		if !strings.has_prefix(w, "$(") ||
		   !strings.has_suffix(w, ")") ||
		   strings.has_prefix(w, "$((") {
			return rc_keep("eval of something other than \"$(...)\"")
		}
		// Unquoted $(...) is word-split and globbed before eval: not the same
		// as sourcing the output.
		if !strings.contains(raw, `"$(`) {
			return rc_keep("eval of an unquoted $(...)")
		}
		stmts := shell_parse_statements(w[2:len(w) - 1], .POSIX)
		if len(stmts) != 1 || len(stmts[0].error) > 0 {
			return rc_keep("eval of a compound command")
		}
		inner = stmts[0].tokens[:]
	} else {
		// source <( ... )
		if len(toks) < 5 ||
		   toks[1].kind != .Op ||
		   toks[1].op != "<" ||
		   toks[2].kind != .Op ||
		   toks[2].op != "(" ||
		   toks[len(toks) - 1].kind != .Op ||
		   toks[len(toks) - 1].op != ")" {
			return rc_keep("sources a file")
		}
		inner = toks[3:len(toks) - 1]
	}
	if !ctx.interactive {
		return rc_keep("generator outside the interactive rc file")
	}
	cmd, args, argv, reason, ok := rc_generator_from_tokens(inner, ctx)
	if !ok {
		return rc_keep(reason)
	}
	return RcClass{kind = .GENERATOR, cmd = cmd, args = args, argv = argv}
}

// fish: `cmd args | source`
@(private = "file")
rc_classify_fish_generator :: proc(toks: []ShellToken, ctx: RcContext) -> RcClass {
	n := len(toks)
	if n < 3 ||
	   toks[n - 2].kind != .Op ||
	   toks[n - 2].op != "|" ||
	   toks[n - 1].kind != .Word ||
	   (toks[n - 1].word.text != "source" && toks[n - 1].word.text != ".") {
		return rc_keep("not a recognised pattern")
	}
	if !ctx.interactive {
		return rc_keep("generator outside the interactive rc file")
	}
	cmd, args, argv, reason, ok := rc_generator_from_tokens(toks[:n - 2], ctx)
	if !ok {
		return rc_keep(reason)
	}
	return RcClass{kind = .GENERATOR, cmd = cmd, args = args, argv = argv}
}

// `autoload [-Uz] compinit`, `compinit [-C -i -u -d FILE]`, joined by ; / &&.
@(private = "file")
rc_classify_compinit :: proc(toks: []ShellToken) -> RcClass {
	i := 0
	seen := false
	for i < len(toks) {
		// One simple command up to the next ; or &&.
		j := i
		for j < len(toks) && toks[j].kind == .Word {j += 1}
		cmd := toks[i:j]
		if len(cmd) == 0 {
			return rc_keep("not a compinit call")
		}
		for t, k in cmd {
			// The dump file after -d may be `~/...` / "$ZDOTDIR/...".
			if k > 0 && cmd[k - 1].word.text == "-d" {
				continue
			}
			if !rc_word_literal(t.word) {
				return rc_keep("compinit with expansions")
			}
		}
		switch cmd[0].word.text {
		case "autoload":
			names := 0
			for t in cmd[1:] {
				w := t.word.text
				if strings.has_prefix(w, "-") || strings.has_prefix(w, "+") {
					continue
				}
				if w != "compinit" {
					return rc_keep("autoloads other functions")
				}
				names += 1
			}
			if names != 1 {
				return rc_keep("not a compinit call")
			}
		case "compinit":
			for k := 1; k < len(cmd); k += 1 {
				w := cmd[k].word.text
				if w == "-d" && k + 1 < len(cmd) {
					k += 1; continue
				}
				if !strings.has_prefix(w, "-") {
					return rc_keep("compinit with arguments")
				}
			}
			seen = true
		case:
			return rc_keep("not a compinit call")
		}
		if j < len(toks) {
			op := toks[j].op
			if op != ";" && op != "&&" {
				return rc_keep("compinit combined with other commands")
			}
			j += 1
		}
		i = j
	}
	_ = seen
	return RcClass{kind = .COMPINIT}
}

// `alias name=value` (zsh/bash/fish) or `alias name value` (fish).
@(private = "file")
rc_classify_alias :: proc(toks: []ShellToken, ctx: RcContext) -> RcClass {
	for t in toks {
		if t.kind != .Word {
			return rc_keep("alias combined with other commands")
		}
	}
	name, value: string
	vw: ShellWord
	switch {
	case len(toks) == 2:
		w := toks[1].word
		eq := strings.index_byte(w.text, '=')
		if eq <= 0 {
			return rc_keep("alias lookup, not a definition")
		}
		name = w.text[:eq]
		value = w.text[eq + 1:]
		vw = ShellWord {
			text   = value,
			active = w.active[eq + 1:],
		}
		if !rc_word_literal(ShellWord{text = name, active = w.active[:eq]}) {
			return rc_keep("alias name with expansions")
		}
	case len(toks) == 3 && ctx.shell == .FISH:
		name = toks[1].word.text
		vw = toks[2].word
		value = vw.text
		if !rc_word_literal(toks[1].word) {
			return rc_keep("alias name with expansions")
		}
	case:
		return rc_keep("alias with options or several definitions")
	}
	if !is_safe_alias_name(name) || strings.has_prefix(name, "-") {
		return rc_keep("alias name wayu can't manage")
	}
	if len(value) == 0 {
		return rc_keep("empty alias")
	}
	if !rc_word_literal(vw) {
		return rc_keep("alias value is expanded when defined")
	}
	if strings.contains_any(value, "\n\r") {
		return rc_keep("multi-line alias")
	}
	return RcClass{kind = .ALIAS, name = name, value = value}
}

// A shell word as a wayu value (see RcClass). Expansions allowed: `$NAME` /
// `${NAME}` of known variables and a leading `~`.
rc_word_value :: proc(
	text: string,
	active: []bool,
	ctx: RcContext,
) -> (
	value: string,
	reason: string,
	ok: bool,
) {
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(text) {
		c := text[i]
		if !active[i] {
			// A quoted `$NAME` stays literal in the shell but would expand
			// in wayu; a quoted leading `~` likewise.
			if c == '$' &&
			   i + 1 < len(text) &&
			   (text[i + 1] == '{' || var_name_prefix_len(text[i + 1:]) > 0) {
				return "", "quoted '$'", false
			}
			if c == '~' && i == 0 {
				return "", "quoted '~'", false
			}
			strings.write_byte(&b, c)
			i += 1
			continue
		}
		switch c {
		case '$':
			rest := text[i + 1:]
			name: string
			if len(rest) > 0 && rest[0] == '{' {
				n := var_name_prefix_len(rest[1:])
				if n == 0 || 1 + n >= len(rest) || rest[1 + n] != '}' {
					return "", "parameter expansion", false
				}
				name = rest[1:1 + n]
				i += 3 + n
			} else {
				n := var_name_prefix_len(rest)
				if n == 0 {
					return "", "command substitution or special parameter", false
				}
				name = rest[:n]
				i += 1 + n
			}
			if !slice.contains(ctx.known_vars, name) && !slice.contains(RC_BASE_VARS, name) {
				return "", fmt.tprintf("uses $%s, which wayu doesn't define", name), false
			}
			if i < len(text) && var_name_prefix_len(text[i:i + 1]) > 0 ||
			   (i < len(text) && text[i] >= '0' && text[i] <= '9') {
				fmt.sbprintf(&b, "${{%s}}", name)
			} else {
				fmt.sbprintf(&b, "$%s", name)
			}
		case '~':
			if i != 0 || (len(text) > 1 && text[1] != '/') {
				return "", "'~' that wayu can't expand", false
			}
			strings.write_string(&b, "$HOME")
			i += 1
		case '`', '*', '?', '[', ']', '{', '}', '!':
			return "", "expansion wayu can't reproduce", false
		case:
			strings.write_byte(&b, c)
			i += 1
		}
	}
	return strings.to_string(b), "", true
}

// `export NAME=value` / `set -gx NAME value`
@(private = "file")
rc_classify_env :: proc(name, text: string, active: []bool, ctx: RcContext) -> RcClass {
	if !is_shell_var_name(name) {
		return rc_keep("not a variable name")
	}
	if slice.contains(RC_ENV_DENY, name) ||
	   strings.has_prefix(name, "WAYU_") ||
	   strings.has_prefix(name, "_WAYU") {
		return rc_keep("a variable wayu or the shell manages")
	}
	if len(text) == 0 {
		return rc_keep("empty value")
	}
	value, reason, ok := rc_word_value(text, active, ctx)
	if !ok {
		return rc_keep(reason)
	}
	if strings.contains_any(value, "\n\r") {
		return rc_keep("multi-line value")
	}
	secret := looks_secret(name, value)
	if secret && strings.contains_rune(value, '$') {
		return rc_keep("secret-looking value with variables")
	}
	return RcClass{kind = .ENV, name = name, value = value, secret = secret}
}

// Is `s` a reference to variable `name`: `$name` / `${name}` (and, for zsh
// arrays, `$name[@]` / `${name[@]}`)? (Built with concatenation: fmt
// formats read `{` as an argument index.)
@(private = "file")
rc_is_self_ref :: proc(s, name: string, array: bool) -> bool {
	t := context.temp_allocator
	if s == strings.concatenate({"$", name}, t) || s == strings.concatenate({"${", name, "}"}, t) {
		return true
	}
	return(
		array &&
		(s == strings.concatenate({"$", name, "[@]"}, t) ||
				s == strings.concatenate({"${", name, "[@]}"}, t)) \
	)
}

// `PATH=a:b:$PATH:c` (also FPATH): dirs before $PATH are prepended, after
// it appended.
@(private = "file")
rc_classify_colon_list :: proc(name, text: string, active: []bool, ctx: RcContext) -> RcClass {
	pre := make([dynamic]string, context.temp_allocator)
	post := make([dynamic]string, context.temp_allocator)
	seen_self := false
	start := 0
	for i := 0; i <= len(text); i += 1 {
		if i < len(text) && text[i] != ':' {
			continue
		}
		seg, seg_active := text[start:i], active[start:i]
		start = i + 1
		if rc_is_self_ref(seg, name, false) && len(seg_active) > 0 && seg_active[0] {
			if seen_self {
				return rc_keep(fmt.tprintf("$%s appears twice", name))
			}
			seen_self = true
			continue
		}
		if len(seg) == 0 {
			return rc_keep("empty entry (the current directory)")
		}
		v, reason, ok := rc_word_value(seg, seg_active, ctx)
		if !ok {
			return rc_keep(reason)
		}
		append(&post if seen_self else &pre, v)
	}
	if !seen_self {
		return rc_keep(fmt.tprintf("replaces $%s instead of extending it", name))
	}
	if len(pre) + len(post) == 0 {
		return rc_keep("no directories")
	}
	return RcClass {
		kind = .FPATH if name == "FPATH" else .PATH,
		prepend = pre[:],
		appends = post[:],
	}
}

// zsh `path=(a $path)`, `fpath=($fpath b)`, `fpath+=(b)`, `fpath+=b`.
@(private = "file")
rc_classify_zsh_array :: proc(
	name: string,
	appending: bool,
	rhs: string,
	toks: []ShellToken,
	ctx: RcContext,
) -> RcClass {
	words: []ShellToken
	if len(rhs) > 0 {
		// `fpath+=dir` (one element) — `fpath=dir` would replace it.
		if !appending || len(toks) != 1 {
			return rc_keep("replaces the array")
		}
		w := toks[0].word
		v, reason, ok := rc_word_value(rhs, w.active[len(w.text) - len(rhs):], ctx)
		if !ok {
			return rc_keep(reason)
		}
		out := make([]string, 1, context.temp_allocator)
		out[0] = v
		return RcClass{kind = .FPATH if name == "fpath" else .PATH, appends = out}
	}
	if len(toks) < 3 ||
	   toks[1].kind != .Op ||
	   toks[1].op != "(" ||
	   toks[len(toks) - 1].kind != .Op ||
	   toks[len(toks) - 1].op != ")" {
		return rc_keep("not an array assignment")
	}
	words = toks[2:len(toks) - 1]
	pre := make([dynamic]string, context.temp_allocator)
	post := make([dynamic]string, context.temp_allocator)
	seen_self := appending
	for t in words {
		if t.kind != .Word {
			return rc_keep("array with operators")
		}
		w := t.word
		if rc_is_self_ref(w.text, name, true) {
			if seen_self {
				return rc_keep(fmt.tprintf("$%s appears twice", name))
			}
			seen_self = true
			continue
		}
		v, reason, ok := rc_word_value(w.text, w.active, ctx)
		if !ok {
			return rc_keep(reason)
		}
		append(&post if seen_self else &pre, v)
	}
	if !seen_self {
		return rc_keep(fmt.tprintf("replaces $%s instead of extending it", name))
	}
	if len(pre) + len(post) == 0 {
		return rc_keep("no directories")
	}
	return RcClass {
		kind = .FPATH if name == "fpath" else .PATH,
		prepend = pre[:],
		appends = post[:],
	}
}

// fish `set -gx NAME value` / `set -gx PATH dir $PATH`
@(private = "file")
rc_classify_fish_set :: proc(toks: []ShellToken, ctx: RcContext) -> RcClass {
	exported, global, universal := false, false, false
	i := 1
	for i < len(toks) && toks[i].kind == .Word && strings.has_prefix(toks[i].word.text, "-") {
		f := toks[i].word.text
		switch f {
		case "--export":
			exported = true
		case "--global":
			global = true
		case "--universal":
			universal = true
		case:
			if strings.has_prefix(f, "--") {
				return rc_keep("set with options wayu doesn't model")
			}
			for c in f[1:] {
				switch c {
				case 'x':
					exported = true
				case 'g':
					global = true
				case 'U':
					universal = true
				case:
					return rc_keep("set with options wayu doesn't model")
				}
			}
		}
		i += 1
	}
	if universal {
		return rc_keep("universal variable (persisted by fish)")
	}
	_ = global
	if i >= len(toks) || toks[i].kind != .Word {
		return rc_keep("set without a name")
	}
	name := toks[i].word.text
	vals := toks[i + 1:]
	for t in vals {
		if t.kind != .Word {
			return rc_keep("set combined with other commands")
		}
	}
	if name == "PATH" {
		pre := make([dynamic]string, context.temp_allocator)
		post := make([dynamic]string, context.temp_allocator)
		seen_self := false
		for t in vals {
			if t.word.text == "$PATH" && t.word.active[0] {
				if seen_self {
					return rc_keep("$PATH appears twice")
				}
				seen_self = true
				continue
			}
			v, reason, ok := rc_word_value(t.word.text, t.word.active, ctx)
			if !ok {
				return rc_keep(reason)
			}
			append(&post if seen_self else &pre, v)
		}
		if !seen_self {
			return rc_keep("replaces $PATH instead of extending it")
		}
		if len(pre) + len(post) == 0 {
			return rc_keep("no directories")
		}
		return RcClass{kind = .PATH, prepend = pre[:], appends = post[:]}
	}
	if !exported {
		return rc_keep("not exported")
	}
	if len(vals) != 1 {
		return rc_keep("list value")
	}
	return rc_classify_env(name, vals[0].word.text, vals[0].word.active, ctx)
}

// fish `fish_add_path [-g -p -a -m -P] dir...`
@(private = "file")
rc_classify_fish_add_path :: proc(toks: []ShellToken, ctx: RcContext) -> RcClass {
	appending := false
	dirs := make([dynamic]string, context.temp_allocator)
	for t in toks[1:] {
		if t.kind != .Word {
			return rc_keep("fish_add_path combined with other commands")
		}
		w := t.word.text
		if strings.has_prefix(w, "-") {
			switch w {
			case "-a", "--append":
				appending = true
			case "-p",
			     "--prepend",
			     "-g",
			     "--global",
			     "-U",
			     "--universal",
			     "-m",
			     "--move",
			     "-P",
			     "--path":
			case:
				return rc_keep("fish_add_path with options wayu doesn't model")
			}
			continue
		}
		v, reason, ok := rc_word_value(w, t.word.active, ctx)
		if !ok {
			return rc_keep(reason)
		}
		append(&dirs, v)
	}
	if len(dirs) == 0 {
		return rc_keep("no directories")
	}
	if appending {
		return RcClass{kind = .PATH, appends = dirs[:]}
	}
	return RcClass{kind = .PATH, prepend = dirs[:]}
}

// One statement of an rc file and its class.
RcFinding :: struct {
	first_line: int, // 1-based, inclusive
	last_line:  int,
	class:      RcClass,
}

// Block nesting after a statement. kw: if/case/for/while/until/select/
// repeat/{ (fish: if/for/while/function/begin/switch) minus their closers;
// paren: `(` minus `)` (an unmatched `)` is a case pattern: ignored).
RcDepth :: struct {
	kw:    int,
	paren: int,
}

@(private = "file")
rc_depth_delta :: proc(toks: []ShellToken, fish: bool, d: ^RcDepth) {
	cmdpos := true
	for t in toks {
		if t.kind == .Op {
			switch t.op {
			case "(":
				d.paren += 1
			case ")":
				if d.paren > 0 {
					d.paren -= 1
				}
			}
			cmdpos = true
			continue
		}
		w := t.word.text
		if fish {
			if cmdpos {
				switch w {
				case "if", "for", "while", "function", "begin", "switch":
					d.kw += 1
				case "end":
					if d.kw > 0 {
						d.kw -= 1
					}
				}
			}
			// `else if` continues the open `if`.
			cmdpos = w == "and" || w == "or" || w == "not" || w == "begin"
			continue
		}
		switch w {
		case "{":
			d.kw += 1
			cmdpos = true
			continue
		case "}":
			if d.kw > 0 {
				d.kw -= 1
			}
			cmdpos = true
			continue
		}
		if cmdpos {
			switch w {
			case "if", "case", "for", "while", "until", "select", "repeat":
				d.kw += 1
			case "fi", "esac", "done":
				if d.kw > 0 {
					d.kw -= 1
				}
			}
		}
		switch w {
		case "then", "do", "else", "elif", "if", "while", "until", "!", "function":
			cmdpos = true
		case:
			cmdpos = false
		}
	}
}

// Classify every top-level statement of an rc file's `content` and return
// the movable ones. Statements before the line that loads wayu (unless
// `after_loader`), inside blocks, or after a statement the tokenizer could
// not read are never returned. `loaded`: wayu is loaded by the end of the
// content. ctx.known_vars grows with the constants found movable (in order).
rc_scan_content :: proc(
	content: string,
	ctx: ^RcContext,
	after_loader: bool,
) -> (
	findings: [dynamic]RcFinding,
	loaded: bool,
) {
	context.allocator = context.temp_allocator
	findings = make([dynamic]RcFinding, context.temp_allocator)
	loaded = after_loader
	fish := ctx.shell == .FISH
	stmts := shell_parse_statements(content, .FISH if fish else .POSIX)
	lines := strings.split(content, "\n", context.temp_allocator)
	depth: RcDepth
	for st in stmts {
		if len(st.error) > 0 {
			break
		} // nothing after it can be trusted
		before := depth
		rc_depth_delta(st.tokens[:], fish, &depth)
		raw := strings.join(
			lines[st.first_line - 1:min(st.last_line, len(lines))],
			"\n",
			context.temp_allocator,
		)
		if !loaded {
			if rc_loads_wayu(raw) {
				loaded = true
			}
			continue
		}
		if before != {} || depth != {} {
			continue
		}
		c := rc_classify_statement(st.tokens[:], raw, ctx^)
		if c.kind == .KEEP {
			continue
		}
		if c.kind == .ENV {
			kv := make([dynamic]string, context.temp_allocator)
			append(&kv, ..ctx.known_vars)
			append(&kv, c.name)
			ctx.known_vars = kv[:]
		}
		append(&findings, RcFinding{st.first_line, st.last_line, c})
	}
	return
}

// ============================================================================
// Plan: which files, which lines, what goes into the store
// ============================================================================

// Startup files of `shell` in LOAD order (fish: conf.d before config.fish),
// existing or not, temp-allocated. `interactive` marks the file generator
// lines may move from.
OptimizeRcFile :: struct {
	path:        string,
	interactive: bool,
}

optimize_rc_files :: proc(shell: ShellType) -> []OptimizeRcFile {
	files := shell_startup_files(shell, context.temp_allocator)
	out := make([dynamic]OptimizeRcFile, context.temp_allocator)
	switch shell {
	case .FISH:
		// conf.d/*.fish run before config.fish.
		for f in files[1:] {append(&out, OptimizeRcFile{f, true})}
		if len(files) > 0 {
			append(&out, OptimizeRcFile{files[0], true})
		}
	case .ZSH:
		for f in files {append(&out, OptimizeRcFile{f, strings.has_suffix(f, "/.zshrc")})}
	case .BASH:
		for f in files {append(&out, OptimizeRcFile{f, strings.has_suffix(f, "/.bashrc")})}
	case .UNKNOWN:
	}
	return out[:]
}

OptimizeFile :: struct {
	path:     string,
	content:  string,
	findings: []RcFinding,
}

OptimizePlan :: struct {
	shell:  ShellType,
	loaded: bool, // some startup file loads wayu
	files:  [dynamic]OptimizeFile, // only files with findings, load order
}

optimize_plan_count :: proc(plan: ^OptimizePlan) -> (n: int) {
	for f in plan.files {
		for fd in f.findings {
			if fd.class.kind != .KEEP {
				n += 1
			}
		}
	}
	return
}

// Scan the startup files of `shell`. `store` provides the constants a moved
// value may reference. Everything is temp-allocated.
optimize_build_plan :: proc(shell: ShellType, store: ^EntryStore) -> OptimizePlan {
	plan := OptimizePlan {
		shell = shell,
	}
	plan.files = make([dynamic]OptimizeFile, context.temp_allocator)
	known := make([dynamic]string, context.temp_allocator)
	for e in store.env {append(&known, e.name)}
	ctx := RcContext {
		shell      = shell,
		known_vars = known[:],
	}
	for f in optimize_rc_files(shell) {
		if !os.is_file(f.path) {
			continue
		}
		data, err := os.read_entire_file(f.path, context.temp_allocator)
		if err != nil {
			continue
		}
		ctx.interactive = f.interactive
		findings, loaded := rc_scan_content(string(data), &ctx, plan.loaded)
		plan.loaded = loaded
		if len(findings) > 0 {
			append(&plan.files, OptimizeFile{f.path, string(data), findings[:]})
		}
	}
	return plan
}

// The file's content without the lines of its movable findings.
optimize_new_content :: proc(f: OptimizeFile, allocator := context.temp_allocator) -> string {
	lines := strings.split(f.content, "\n", context.temp_allocator)
	drop := make([]bool, len(lines), context.temp_allocator)
	for fd in f.findings {
		if fd.class.kind == .KEEP {
			continue
		}
		for l in fd.first_line ..= fd.last_line {
			if l - 1 < len(drop) {
				drop[l - 1] = true
			}
		}
	}
	b := strings.builder_make(allocator)
	first := true
	for l, i in lines {
		if drop[i] {
			continue
		}
		if !first {
			strings.write_byte(&b, '\n')
		}
		strings.write_string(&b, l)
		first = false
	}
	return strings.to_string(b)
}

// `~/x` for paths under $HOME (messages).
optimize_tilde :: proc(path: string) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if len(home) > 0 &&
	   strings.has_prefix(path, home) &&
	   len(path) > len(home) &&
	   path[len(home)] == '/' {
		return fmt.tprintf("~%s", path[len(home):])
	}
	return path
}

// The backup group name `wayu backup restore` takes for an rc file.
optimize_backup_name :: proc(path: string) -> string {
	return backup_key(path, context.temp_allocator)
}

// Unified diff (removals only) of `f` against its optimized content, with
// 3 lines of context.
optimize_file_diff :: proc(f: OptimizeFile) -> string {
	lines := strings.split(f.content, "\n", context.temp_allocator)
	if len(lines) > 0 && lines[len(lines) - 1] == "" {
		lines = lines[:len(lines) - 1]
	}
	n := len(lines)
	drop := make([]bool, n, context.temp_allocator)
	for fd in f.findings {
		if fd.class.kind == .KEEP {
			continue
		}
		for l in fd.first_line ..= fd.last_line {
			if l - 1 < n {
				drop[l - 1] = true
			}
		}
	}
	b := strings.builder_make(context.temp_allocator)
	shown := optimize_tilde(f.path)
	fmt.sbprintfln(&b, "%s--- %s%s", BOLD, shown, RESET)
	fmt.sbprintfln(&b, "%s+++ %s (optimized)%s", BOLD, shown, RESET)
	CONTEXT :: 3
	dropped_before := 0
	i := 0
	for i < n {
		if !drop[i] {
			i += 1; continue
		}
		start := max(0, i - CONTEXT)
		last := i
		for j := i; j < n && j - last <= 2 * CONTEXT; j += 1 {
			if drop[j] {
				last = j
			}
		}
		end := min(n, last + CONTEXT + 1)
		removed := 0
		for k in start ..< end {
			if drop[k] {
				removed += 1
			}
		}
		// Lines dropped before this hunk shift its position in the new file.
		pre := 0
		for k in 0 ..< start {
			if drop[k] {
				pre += 1
			}
		}
		dropped_before = pre
		old_len := end - start
		fmt.sbprintfln(
			&b,
			"%s@@ -%d,%d +%d,%d @@%s",
			get_primary(),
			start + 1,
			old_len,
			start + 1 - dropped_before,
			old_len - removed,
			RESET,
		)
		for k in start ..< end {
			if drop[k] {
				fmt.sbprintfln(&b, "%s-%s%s", get_error(), lines[k], RESET)
			} else {
				fmt.sbprintfln(&b, " %s", lines[k])
			}
		}
		i = end
	}
	return strings.to_string(b)
}

// One line describing what a finding becomes in wayu.
optimize_describe :: proc(c: RcClass, shell: ShellType) -> string {
	switch c.kind {
	case .GENERATOR:
		return fmt.tprintf(
			"generator  %s %s  (%s, cached by the evalcache)",
			c.cmd,
			c.args,
			shell_config_name(shell),
		)
	case .FPATH:
		all := make([dynamic]string, context.temp_allocator)
		append(&all, ..c.prepend)
		append(&all, ..c.appends)
		note := "" if len(c.appends) == 0 else "  (was appended; wayu puts it in front)"
		return fmt.tprintf(
			"fpath      %s%s",
			strings.join(all[:], " ", context.temp_allocator),
			note,
		)
	case .COMPINIT:
		return "compinit   removed (wayu already runs compinit)"
	case .PATH:
		parts := make([dynamic]string, context.temp_allocator)
		for d in c.prepend {append(&parts, fmt.tprintf("%s (front)", d))}
		for d in c.appends {append(&parts, fmt.tprintf("%s (end of the wayu list; was appended)", d))}
		return fmt.tprintf("path       %s", strings.join(parts[:], ", ", context.temp_allocator))
	case .ALIAS:
		return fmt.tprintf("alias      %s = %s", c.name, c.value)
	case .ENV:
		if c.secret {
			return fmt.tprintf("const      %s  (secret: stored encrypted)", c.name)
		}
		return fmt.tprintf("const      %s = %s", c.name, c.value)
	case .KEEP:
		return fmt.tprintf("kept       %s", c.reason)
	}
	return ""
}

// Normalized form of a stored dir for comparisons (`~/x` == `$HOME/x`).
@(private = "file")
optimize_norm_dir :: proc(d: string) -> string {
	return expand_leading_tilde_to_home_var(d, context.temp_allocator)
}

@(private = "file")
optimize_index :: proc(list: []string, v: string) -> int {
	for x, i in list {
		if optimize_norm_dir(x) == optimize_norm_dir(v) {
			return i
		}
	}
	return -1
}

// Final order of a dir list (PATH entries or fpath) after the rc lines ran:
// each prepend puts its dirs in front (later lines further front, a line's
// own dirs left to right); appends only add dirs not already listed (the
// first occurrence wins a lookup, so appending a present dir is a no-op).
// Returns the new list (temp) and whether it differs from `existing`.
optimize_merge_dirs :: proc(
	existing: []string,
	findings: []RcClass,
) -> (
	out: []string,
	changed: bool,
) {
	front := make([dynamic]string, context.temp_allocator)
	back := make([dynamic]string, context.temp_allocator)
	for c in findings {
		if len(c.prepend) > 0 {
			nf := make([dynamic]string, context.temp_allocator)
			append(&nf, ..c.prepend)
			for x in front {
				if optimize_index(c.prepend, x) < 0 {
					append(&nf, x)
				}
			}
			front = nf
			for d in c.prepend {
				if i := optimize_index(back[:], d); i >= 0 {
					ordered_remove(&back, i)
				}
			}
		}
		for d in c.appends {
			if optimize_index(front[:], d) >= 0 ||
			   optimize_index(back[:], d) >= 0 ||
			   optimize_index(existing, d) >= 0 {
				continue
			}
			append(&back, d)
		}
	}
	res := make([dynamic]string, context.temp_allocator)
	for d in front {
		if optimize_index(res[:], d) < 0 {
			append(&res, d)
		}
	}
	for d in existing {
		if optimize_index(front[:], d) >= 0 || optimize_index(back[:], d) >= 0 {
			continue
		}
		if optimize_index(res[:], d) < 0 {
			append(&res, d)
		}
	}
	for d in back {
		if optimize_index(res[:], d) < 0 {
			append(&res, d)
		}
	}
	if len(res) != len(existing) {
		return res[:], true
	}
	for d, i in res {
		if optimize_norm_dir(d) != optimize_norm_dir(existing[i]) {
			return res[:], true
		}
	}
	return res[:], false
}

// Apply the plan's findings to `store` (heap strings, owned by the store).
// Returns whether anything changed. Secret constants become markers (the
// caller stores their values with secrets_set).
optimize_merge_store :: proc(store: ^EntryStore, plan: ^OptimizePlan) -> (changed: bool) {
	paths := make([dynamic]RcClass, context.temp_allocator)
	fpaths := make([dynamic]RcClass, context.temp_allocator)
	tools := read_wayu_toml_tools()
	defer {
		for &t in tools {destroy_tool_entry(&t)}
		delete(tools)
	}
	shell_name := shell_config_name(plan.shell)
	for f in plan.files {
		for fd in f.findings {
			c := fd.class
			#partial switch c.kind {
			case .PATH:
				append(&paths, c)
			case .FPATH:
				append(&fpaths, c)
			case .GENERATOR:
				dup := false
				for t in tools {
					if tool_kind_is_evalcache(t.kind) && t.name == c.cmd && t.args == c.args {
						dup = true
					}
				}
				for g in store.generators {
					if g.shell == shell_name && g.cmd == c.cmd && g.args == c.args {
						dup = true
					}
				}
				if !dup {
					append(
						&store.generators,
						StoreGenerator {
							strings.clone(shell_name),
							strings.clone(c.cmd),
							strings.clone(c.args),
						},
					)
					changed = true
				}
			case .ALIAS:
				if i := entries_find(store, .ALIAS, c.name); i >= 0 {
					if store.aliases[i].value != c.value {
						delete(store.aliases[i].value)
						store.aliases[i].value = strings.clone(c.value)
						changed = true
					}
				} else {
					append(
						&store.aliases,
						StoreAlias{strings.clone(c.name), strings.clone(c.value)},
					)
					changed = true
				}
			case .ENV:
				i := entries_find(store, .ENV, c.name)
				// A constant that is already a secret stays one.
				secret := c.secret || (i >= 0 && store.env[i].secret)
				if i >= 0 {
					e := &store.env[i]
					if secret {
						if !e.secret || len(e.value) > 0 {
							changed = true
						}
						delete(e.value)
						e.value = ""
						e.secret = true
					} else if e.value != c.value {
						delete(e.value)
						e.value = strings.clone(c.value)
						changed = true
					}
				} else {
					append(
						&store.env,
						StoreEnv {
							name = strings.clone(c.name),
							value = "" if secret else strings.clone(c.value),
							secret = secret,
						},
					)
					changed = true
				}
			}
		}
	}
	if len(paths) > 0 {
		existing := make([dynamic]string, context.temp_allocator)
		for p in store.paths {append(&existing, p.dir)}
		merged, ch := optimize_merge_dirs(existing[:], paths[:])
		if ch {
			taken := make(map[string]bool, allocator = context.temp_allocator)
			for p in store.paths {taken[p.key] = true}
			np := make([dynamic]StorePath, 0, len(merged))
			for d in merged {
				if i := optimize_index(existing[:], d); i >= 0 {
					append(&np, store.paths[i])
					store.paths[i] = {}
					continue
				}
				expanded := d
				if home := os.get_env("HOME", context.temp_allocator); len(home) > 0 {
					expanded, _ = strings.replace_all(d, "$HOME", home, context.temp_allocator)
				}
				key := derive_path_key(expanded, taken)
				taken[key] = true
				append(&np, StorePath{key, strings.clone(d)})
			}
			for p in store.paths {delete(p.key); delete(p.dir)} 	// the moved ones are zeroed
			delete(store.paths)
			store.paths = np
			changed = true
		}
	}
	if len(fpaths) > 0 {
		// Appends go in front too: wayu has one fpath list.
		as_prepend := make([dynamic]RcClass, context.temp_allocator)
		for c in fpaths {
			all := make([dynamic]string, context.temp_allocator)
			append(&all, ..c.prepend)
			append(&all, ..c.appends)
			append(&as_prepend, RcClass{kind = .FPATH, prepend = all[:]})
		}
		merged, ch := optimize_merge_dirs(store.fpath[:], as_prepend[:])
		if ch {
			nf := make([dynamic]string, 0, len(merged))
			for d in merged {append(&nf, strings.clone(d))}
			for f in store.fpath {delete(f)}
			delete(store.fpath)
			store.fpath = nf
			changed = true
		}
	}
	return
}

// ============================================================================
// Apply
// ============================================================================

// <data>/rc_check.stamp: mtime = last time the prompt hook's rc check ran.
optimize_stamp_path :: proc() -> string {
	return fmt.tprintf("%s/rc_check.stamp", wayu.data)
}

@(private = "file")
optimize_touch_stamp :: proc() {
	if !os.is_dir(wayu.data) {
		return
	}
	_ = os.write_entire_file_from_string(optimize_stamp_path(), "")
}

// Move the plan's lines into wayu: secrets first (a secret that can't be
// stored keeps its line), then entries.json, then each rc file (backup,
// atomic write). Under the config lock; the caller regenerates core.
// Returns the number of statements moved. `quiet`: no warnings on stdout.
optimize_apply :: proc(
	plan: ^OptimizePlan,
	quiet := false,
) -> (
	moved: int,
	ok: bool,
	err: string,
) {
	if !config_lock_acquire() {
		return 0, false, "could not lock the wayu config"
	}
	defer config_lock_release()

	// The files must still be what the plan was computed from.
	for f in plan.files {
		data, rerr := os.read_entire_file(f.path, context.temp_allocator)
		if rerr != nil || string(data) != f.content {
			return 0, false, fmt.tprintf(
				"%s changed while optimizing; run 'wayu optimize' again",
				optimize_tilde(f.path),
			)
		}
	}

	store, serr, sok := entries_read()
	if !sok {
		return 0, false, serr
	}
	defer entries_store_destroy(&store)

	for &f in plan.files {
		for &fd in f.findings {
			c := &fd.class
			if c.kind != .ENV {
				continue
			}
			secret := c.secret
			if i := entries_find(&store, .ENV, c.name); i >= 0 && store.env[i].secret {
				secret = true
			}
			if !secret {
				continue
			}
			if _, ok2, e := secrets_set(c.name, c.value); !ok2 {
				if !quiet {
					print_warning(
						"%s stays in %s: cannot store it encrypted (%s)",
						c.name,
						optimize_tilde(f.path),
						e,
					)
				}
				c.kind = .KEEP
				c.reason = "secret could not be stored"
			}
		}
	}

	if optimize_merge_store(&store, plan) {
		if !entries_save(&store) {
			return 0, false, fmt.tprintf("could not update %s", ENTRIES_FILE)
		}
	}

	for f in plan.files {
		n := 0
		for fd in f.findings {
			if fd.class.kind != .KEEP {
				n += 1
			}
		}
		if n == 0 {
			continue
		}
		content := optimize_new_content(f)
		if !create_backup_cli(f.path) {
			return moved, false, fmt.tprintf(
				"could not back up %s; it was not changed",
				optimize_tilde(f.path),
			)
		}
		if werr := write_file_atomic(f.path, transmute([]byte)content); werr != nil {
			return moved, false, fmt.tprintf(
				"could not write %s: %v",
				optimize_tilde(f.path),
				werr,
			)
		}
		moved += n
	}
	return moved, true, ""
}

// ============================================================================
// `wayu optimize`
// ============================================================================

handle_optimize_command :: proc(action: Action, args: []string) {
	check, notify := false, false
	for a in args {
		switch a {
		case "--check":
			check = true
		case "--notify":
			notify = true
		case "help", "-h", "--help":
			print_optimize_help()
			return
		case:
			print_error_simple("Unknown argument: %s", a)
			print_optimize_help()
			wayu_exit(EXIT_USAGE)
		}
	}
	if action == .HELP {
		print_optimize_help()
		return
	}
	if notify {
		optimize_notify()
		return
	}
	if wayu.shell == .UNKNOWN {
		print_error_simple("Could not determine your shell - pass --shell zsh|bash|fish")
		wayu_exit(EXIT_USAGE)
	}

	store := entries_load()
	defer entries_store_destroy(&store)
	plan := optimize_build_plan(wayu.shell, &store)
	n := optimize_plan_count(&plan)

	if check {
		for f in plan.files {
			for fd in f.findings {
				fmt.printfln(
					"%s:%d: %s",
					optimize_tilde(f.path),
					fd.first_line,
					optimize_describe(fd.class, plan.shell),
				)
			}
		}
		if n > 0 {
			fmt.printfln("%d line%s can be optimized (wayu optimize)", n, "" if n == 1 else "s")
			wayu_exit(EXIT_FAILURE)
		}
		if !plan.loaded {
			fmt.println("wayu is not loaded from any startup file; nothing to check")
		} else {
			fmt.println("Nothing to optimize")
		}
		return
	}

	if !plan.loaded {
		print_info(
			"wayu is not loaded from any %s startup file; only lines after that line are optimized (see 'wayu init')",
			get_shell_name(wayu.shell),
		)
		return
	}
	if n == 0 {
		print_success(
			"Nothing to optimize: no startup-file line after wayu loads can move into wayu",
		)
		return
	}

	optimize_print_plan(&plan)

	if wayu.dry_run {
		print_info("Dry run: nothing was changed. Apply with 'wayu optimize --yes'")
		return
	}
	if !wayu.yes_flag {
		print_error(
			"wayu optimize rewrites your shell startup files (each is backed up first). Pass --yes to apply, or --dry-run to preview.",
		)
		wayu_exit(EXIT_USAGE)
	}

	moved, ok, err := optimize_apply(&plan)
	if !ok {
		print_error_simple("%s", err)
		if moved > 0 {
			regenerate_init_core_silently()
		}
		wayu_exit(EXIT_IOERR)
	}
	regenerate_init_core_silently()
	optimize_touch_stamp()
	print_success(
		"Moved %d line%s into wayu; open a new shell to use them",
		moved,
		"" if moved == 1 else "s",
	)
	for f in plan.files {
		fmt.printfln(
			"  Undo %s: wayu backup restore %s --yes",
			optimize_tilde(f.path),
			optimize_backup_name(f.path),
		)
	}
	fmt.printfln("  (and 'wayu backup restore entries --yes' for the entries)")
}

optimize_print_plan :: proc(plan: ^OptimizePlan) {
	for f in plan.files {
		fmt.print(optimize_file_diff(f))
		fmt.println()
	}
	print_section("Moves into wayu", "📦")
	for f in plan.files {
		for fd in f.findings {
			if fd.class.kind == .KEEP {
				continue
			}
			fmt.printfln(
				"  %s:%d  %s",
				optimize_tilde(f.path),
				fd.first_line,
				optimize_describe(fd.class, plan.shell),
			)
		}
	}
	fmt.println()
}

print_optimize_help :: proc() {
	fmt.println()
	fmt.printfln(
		"%swayu optimize - Move installer lines from your shell startup files into wayu%s",
		BOLD,
		RESET,
	)
	fmt.println()
	fmt.printfln("%sUSAGE:%s", get_primary(), RESET)
	fmt.println("  wayu optimize              Show the diff and what moves into wayu")
	fmt.println("  wayu optimize --dry-run    Same, explicitly without writing")
	fmt.println("  wayu optimize --yes        Apply: back up and rewrite the startup files")
	fmt.println("  wayu optimize --check      Exit 1 when lines can be optimized (no writes)")
	fmt.println()
	fmt.printfln(
		"%sWHAT MOVES (lines after the one that loads wayu, outside blocks):%s",
		get_primary(),
		RESET,
	)
	fmt.println("  source <(tool completion zsh), eval \"$(tool init zsh)\"   -> cached generator")
	fmt.println("  fpath=(dir $fpath)                                       -> completion fpath")
	fmt.println(
		"  compinit / autoload -Uz compinit                         -> removed (wayu runs it)",
	)
	fmt.println("  export PATH=dir:$PATH, path=(dir $path)                  -> PATH entries")
	fmt.println("  alias name=value, export NAME=value                      -> aliases, constants")
	fmt.println("  Secret-looking constants are stored encrypted. Anything else stays.")
	fmt.println()
	fmt.printfln("%sUNDO:%s", get_primary(), RESET)
	fmt.println("  wayu backup restore <rc file key, e.g. .zshrc> --yes")
	fmt.println()
}

// ============================================================================
// Prompt-hook notice / [settings] auto_optimize
// ============================================================================

// `[settings] auto_optimize = true` in wayu.toml.
optimize_auto_enabled :: proc() -> bool {
	content, ok := get_cached_toml_content()
	if !ok {
		return false
	}
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return false
	}
	defer virtual.arena_destroy(&arena)
	doc, _ := toml_doc_parse_alloc(content, virtual.arena_allocator(&arena))
	v := get_toml_value(&doc, "settings.auto_optimize")
	return v != nil && v.type == .BOOLEAN && v.bool_val
}

// `wayu optimize --notify` (run by the prompt hook when a startup file is
// newer than the stamp): count the optimizable lines in the files that
// changed since the last check and print ONE line to stderr, or apply them
// with auto_optimize. Always refreshes the stamp, so the same change is
// reported once. Never exits non-zero.
optimize_notify :: proc() {
	if wayu.shell == .UNKNOWN {
		return
	}
	stamp := optimize_stamp_path()
	since: time.Time
	has_stamp := false
	if fi, err := os.stat(stamp, context.temp_allocator); err == nil {
		since = fi.modification_time
		has_stamp = true
	}
	changed := make([dynamic]string, context.temp_allocator)
	for f in optimize_rc_files(wayu.shell) {
		fi, err := os.stat(f.path, context.temp_allocator)
		if err != nil {
			continue
		}
		if !has_stamp || time.diff(since, fi.modification_time) > 0 {
			append(&changed, f.path)
		}
	}
	defer optimize_touch_stamp()
	if len(changed) == 0 {
		return
	}

	store, _, ok := entries_read()
	if !ok {
		return
	}
	defer entries_store_destroy(&store)
	plan := optimize_build_plan(wayu.shell, &store)
	n := 0
	names := make([dynamic]string, context.temp_allocator)
	for f in plan.files {
		if !slice.contains(changed[:], f.path) {
			continue
		}
		k := 0
		for fd in f.findings {
			if fd.class.kind != .KEEP {
				k += 1
			}
		}
		if k > 0 {
			n += k
			append(&names, optimize_tilde(f.path))
		}
	}
	if n == 0 {
		return
	}
	files := strings.join(names[:], ", ", context.temp_allocator)

	if !optimize_auto_enabled() {
		fmt.eprintfln(
			"wayu: %s changed: %d line%s can be optimized (wayu optimize)",
			files,
			n,
			"" if n == 1 else "s",
		)
		return
	}
	// Only the changed files are rewritten.
	kept := make([dynamic]OptimizeFile, context.temp_allocator)
	for f in plan.files {
		if slice.contains(changed[:], f.path) {
			append(&kept, f)
		}
	}
	plan.files = kept
	moved, aok, err := optimize_apply(&plan, quiet = true)
	if moved > 0 {
		regenerate_init_core_silently()
	}
	if !aok {
		fmt.eprintfln("wayu: auto_optimize: %s", err)
		return
	}
	for f in plan.files {
		for fd in f.findings {
			if fd.class.kind == .KEEP {
				continue
			}
			fmt.eprintfln(
				"wayu: moved %s:%d into wayu: %s",
				optimize_tilde(f.path),
				fd.first_line,
				optimize_describe(fd.class, plan.shell),
			)
		}
	}
	undo := make([dynamic]string, context.temp_allocator)
	for f in plan.files {append(&undo, optimize_backup_name(f.path))}
	fmt.eprintfln(
		"wayu: auto_optimize moved %d line%s (undo: wayu backup restore %s --yes)",
		moved,
		"" if moved == 1 else "s",
		strings.join(undo[:], " / ", context.temp_allocator),
	)
}

// ============================================================================
// Generated shell code (init_generator.odin calls these)
// ============================================================================

// zsh: the managed completion dirs (entries.json `fpath`) in front of fpath,
// right before compinit, in list order; a dir already on fpath is not added
// again (re-sourcing init.zsh).
emit_managed_fpath :: proc(b: ^strings.Builder) {
	store, _, ok := entries_read()
	if !ok {
		return
	}
	defer entries_store_destroy(&store)
	if len(store.fpath) == 0 {
		return
	}
	words := make([dynamic]string, context.temp_allocator)
	for d in store.fpath {
		append(
			&words,
			path_value_shell_word(expand_leading_tilde_to_home_var(d, context.temp_allocator)),
		)
	}
	fmt.sbprintfln(
		b,
		`() {{ emulate -L zsh; local d; for d in "${{(@Oa)argv}}"; do (( ${{fpath[(Ie)$d]}} )) || fpath=( "$d" "${{fpath[@]}}" ); done }} %s`,
		strings.join(words[:], " ", context.temp_allocator),
	)
}

// The cached generators of `shell` (entries.json `generators`), run through
// the evalcache; zsh/bash in interactive shells only (they came from the
// interactive rc file).
emit_generators :: proc(b: ^strings.Builder, shell: ShellType) {
	store, _, ok := entries_read()
	if !ok {
		return
	}
	defer entries_store_destroy(&store)
	name := shell_config_name(shell)
	calls := make([dynamic]string, context.temp_allocator)
	for g in store.generators {
		if g.shell != name {
			continue
		}
		words: string
		reason: string
		valid: bool
		if shell == .FISH {
			words, reason, valid = tool_args_to_fish(g.args)
		} else {
			words, reason, valid = tool_args_to_shell(g.args, context.temp_allocator)
		}
		if !valid {
			append(&calls, fmt.tprintf("# wayu: generator %s: args %s - skipping", g.cmd, reason))
			continue
		}
		append(&calls, fmt.tprintf("_wayu_evalcache %s %s", g.cmd, words))
	}
	if len(calls) == 0 {
		return
	}
	fmt.sbprintln(b, "# === Cached generators (wayu optimize) ===")
	switch shell {
	case .ZSH:
		fmt.sbprintln(b, "if [[ -o interactive ]]; then")
		for c in calls {fmt.sbprintfln(b, "  %s", c)}
		fmt.sbprintln(b, "fi")
	case .BASH:
		fmt.sbprintln(b, "case $- in")
		fmt.sbprintln(b, "  *i*)")
		for c in calls {fmt.sbprintfln(b, "    %s", c)}
		fmt.sbprintln(b, "    ;;")
		fmt.sbprintln(b, "esac")
	case .FISH, .UNKNOWN:
		for c in calls {fmt.sbprintln(b, c)}
	}
	fmt.sbprintln(b)
}

// fish core needs the evalcache helper for generators even without [tools].
fish_has_generators :: proc() -> bool {
	store, _, ok := entries_read()
	if !ok {
		return false
	}
	defer entries_store_destroy(&store)
	for g in store.generators {
		if g.shell == "fish" {
			return true
		}
	}
	return false
}

// Prompt hook: when a startup file is newer than the stamp (`-nt`, a
// builtin test: no fork in the steady state), run `wayu optimize --notify`
// once; it prints the notice (or applies auto_optimize) and refreshes the
// stamp. If the stamp can't be refreshed the check stops for this shell.
emit_rc_watch :: proc(b: ^strings.Builder, shell: ShellType) {
	files := optimize_rc_files(shell)
	if len(files) == 0 {
		return
	}
	stamp := optimize_stamp_path()
	fmt.sbprintln(b, "# === Startup-file watch (wayu optimize notice) ===")
	switch shell {
	case .ZSH, .BASH:
		zsh := shell == .ZSH
		qs := make([dynamic]string, context.temp_allocator)
		for f in files {append(&qs, shell_double_quote_literal(f.path, context.temp_allocator))}
		fmt.sbprintfln(
			b,
			"_WAYU_RC_STAMP=%s",
			shell_double_quote_literal(stamp, context.temp_allocator),
		)
		fmt.sbprintln(b, "_wayu_rc_check() {")
		fmt.sbprintln(b, "  local s=$? f")
		fmt.sbprintln(b, `  [ "${_WAYU_RC_CHECK-1}" = 1 ] || return $s`)
		fmt.sbprintfln(b, "  for f in %s; do", strings.join(qs[:], " ", context.temp_allocator))
		// A missing stamp counts as older: zsh's test -nt is false then.
		fmt.sbprintln(
			b,
			`    if [ -e "$f" ] && { [ ! -e "$_WAYU_RC_STAMP" ] || [ "$f" -nt "$_WAYU_RC_STAMP" ]; }; then`,
		)
		fmt.sbprintfln(
			b,
			`      command "${{_WAYU_BIN:-wayu}}" optimize --notify --shell %s </dev/null >/dev/null`,
			shell_config_name(shell),
		)
		fmt.sbprintln(
			b,
			`      { [ ! -e "$_WAYU_RC_STAMP" ] || [ "$f" -nt "$_WAYU_RC_STAMP" ]; } && _WAYU_RC_CHECK=0`,
		)
		fmt.sbprintln(b, "      break")
		fmt.sbprintln(b, "    fi")
		fmt.sbprintln(b, "  done")
		fmt.sbprintln(b, "  return $s")
		fmt.sbprintln(b, "}")
		if zsh {
			fmt.sbprintln(b, "autoload -Uz add-zsh-hook")
			fmt.sbprintln(b, "add-zsh-hook precmd _wayu_rc_check")
		} else {
			fmt.sbprintln(b, `case ";${PROMPT_COMMAND-};" in`)
			fmt.sbprintln(b, `  *";_wayu_rc_check;"*) ;;`)
			fmt.sbprintln(
				b,
				`  *) PROMPT_COMMAND="_wayu_rc_check${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;`,
			)
			fmt.sbprintln(b, "esac")
		}
	case .FISH:
		fmt.sbprintfln(
			b,
			"set -g _WAYU_RC_STAMP %s",
			escape_fish_string(stamp, context.temp_allocator),
		)
		fmt.sbprintln(b, "function _wayu_rc_check --on-event fish_prompt")
		fmt.sbprintln(b, `    test "$_WAYU_RC_CHECK" != 0; or return 0`)
		qs := make([dynamic]string, context.temp_allocator)
		for f in files {append(&qs, escape_fish_string(f.path, context.temp_allocator))}
		fmt.sbprintfln(b, "    for f in %s", strings.join(qs[:], " ", context.temp_allocator))
		fmt.sbprintln(
			b,
			`        if test -e $f; and begin; not test -e "$_WAYU_RC_STAMP"; or test $f -nt "$_WAYU_RC_STAMP"; end`,
		)
		fmt.sbprintln(b, `            set -l bin wayu`)
		fmt.sbprintln(b, `            test -n "$_WAYU_BIN"; and set bin $_WAYU_BIN`)
		fmt.sbprintln(
			b,
			`            command $bin optimize --notify --shell fish </dev/null >/dev/null`,
		)
		fmt.sbprintln(
			b,
			`            begin; not test -e "$_WAYU_RC_STAMP"; or test $f -nt "$_WAYU_RC_STAMP"; end; and set -g _WAYU_RC_CHECK 0`,
		)
		fmt.sbprintln(b, "            break")
		fmt.sbprintln(b, "        end")
		fmt.sbprintln(b, "    end")
		fmt.sbprintln(b, "end")
	case .UNKNOWN:
	}
	fmt.sbprintln(b)
}

// ============================================================================
// `wayu completions fpath [list|add DIR|rm DIR]`
// ============================================================================

handle_completions_fpath :: proc(args: []string) {
	sub := args[0] if len(args) > 0 else "list"
	rest := args[1:] if len(args) > 0 else nil
	switch sub {
	case "list", "ls":
		store := entries_load()
		defer entries_store_destroy(&store)
		if len(store.fpath) == 0 {
			print_info("No managed completion dirs (wayu completions fpath add DIR)")
			return
		}
		for d in store.fpath {fmt.println(d)}
	case "add", "rm", "remove":
		if len(rest) != 1 {
			print_error_simple("Usage: wayu completions fpath %s DIR", sub)
			wayu_exit(EXIT_USAGE)
		}
		dir := rest[0]
		if len(strings.trim_space(dir)) == 0 || !is_path_entry_safe(dir) {
			print_error_simple("Invalid directory: %q (empty, or contains ':' or a newline)", dir)
			wayu_exit(EXIT_DATAERR)
		}
		config_lock_acquire_or_exit()
		defer config_lock_release()
		store := entries_load()
		defer entries_store_destroy(&store)
		idx := optimize_index(store.fpath[:], dir)
		if sub == "add" {
			if idx >= 0 {
				print_info("Already on the managed fpath: %s", dir)
				return
			}
			if wayu.dry_run {
				print_info("[dry-run] Would add %s to the managed fpath", dir)
				return
			}
			inject_at(&store.fpath, 0, strings.clone(dir))
		} else {
			if idx < 0 {
				print_error_simple("Not on the managed fpath: %s", dir)
				wayu_exit(EXIT_DATAERR)
			}
			if wayu.dry_run {
				print_info("[dry-run] Would remove %s from the managed fpath", dir)
				return
			}
			delete(store.fpath[idx])
			ordered_remove(&store.fpath, idx)
		}
		if !entries_save(&store) {
			wayu_exit(EXIT_IOERR)
		}
		regenerate_init_core_silently()
		print_success(
			"%s %s (zsh: new shells put it on fpath before compinit)",
			"Added" if sub == "add" else "Removed",
			dir,
		)
	case:
		print_error_simple("Unknown fpath action: %s (expected list, add, rm)", sub)
		wayu_exit(EXIT_USAGE)
	}
}

// ============================================================================
// Doctor check
// ============================================================================

// Fixed estimate for a second compinit (the maintainer measured 268 ms).
OPTIMIZE_COMPINIT_COST_MS :: 250

check_rc_optimize :: proc(results: ^[dynamic]CheckResult) {
	ensure_arena_initialized()
	alloc := get_doctor_allocator()
	if wayu.shell == .UNKNOWN {
		return
	}
	store, _, ok := entries_read()
	if !ok {
		return
	} // the entries check reports it
	defer entries_store_destroy(&store)
	plan := optimize_build_plan(wayu.shell, &store)
	n := optimize_plan_count(&plan)
	if n == 0 {
		append(
			results,
			CheckResult {
				name = clone_arena("startup files"),
				status = .OK,
				message = clone_arena(
					"No startup-file line after wayu loads needs to move into wayu",
				),
			},
		)
		return
	}
	parts := make([dynamic]string, context.temp_allocator)
	total := 0
	for f in plan.files {
		for fd in f.findings {
			c := fd.class
			cost := ""
			#partial switch c.kind {
			case .KEEP:
				continue
			case .COMPINIT:
				cost = fmt.tprintf(" (~%d ms)", OPTIMIZE_COMPINIT_COST_MS)
				total += OPTIMIZE_COMPINIT_COST_MS
			case .GENERATOR:
				t0 := time.now()
				r := run_command_timeout(c.argv, 5000)
				command_result_destroy(&r)
				ms := int(time.duration_milliseconds(time.since(t0)))
				cost = fmt.tprintf(" (%d ms per start)", ms)
				total += ms
			}
			label := optimize_describe(c, plan.shell)
			if c.kind == .GENERATOR {
				label = fmt.tprintf("%s %s", c.cmd, c.args)
			}
			append(
				&parts,
				fmt.tprintf(
					"%s:%d %s%s",
					optimize_tilde(f.path),
					fd.first_line,
					strings.trim_space(label),
					cost,
				),
			)
		}
	}
	append(
		results,
		CheckResult {
			name = clone_arena("startup files"),
			status = .WARNING,
			message = fmt.aprintf(
				"%d line%s can move into wayu (~%d ms per start; wayu optimize): %s",
				n,
				"" if n == 1 else "s",
				total,
				strings.join(parts[:], "; ", context.temp_allocator),
				allocator = alloc,
			),
			fixable = true,
		},
	)
}

// doctor --fix: run optimize (the caller requires --yes or --dry-run).
doctor_fix_rc_optimize :: proc() -> (ok: bool, message: string) {
	store, err, sok := entries_read()
	if !sok {
		return false, err
	}
	defer entries_store_destroy(&store)
	plan := optimize_build_plan(wayu.shell, &store)
	n := optimize_plan_count(&plan)
	if n == 0 {
		return true, "nothing to optimize"
	}
	if wayu.dry_run {
		optimize_print_plan(&plan)
		return true, fmt.tprintf("would move %d line%s into wayu", n, "" if n == 1 else "s")
	}
	moved, aok, aerr := optimize_apply(&plan)
	if moved > 0 {
		regenerate_init_core_silently()
	}
	if !aok {
		return false, aerr
	}
	optimize_touch_stamp()
	return true, fmt.tprintf(
		"moved %d line%s into wayu (undo: wayu backup restore <rc file>)",
		moved,
		"" if moved == 1 else "s",
	)
}
