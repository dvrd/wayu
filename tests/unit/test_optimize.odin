// test_optimize.odin - `wayu optimize` (OKAMI-373/374): the rc-line
// classifier, the block-aware scan, the PATH/fpath merge order, the
// entries.json fpath/generators sections, and `config scan` block
// detection.

package test_wayu

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import wayu "../../src"

@(private = "file")
OptCase :: struct {
	line:    string,
	shell:   wayu.ShellType,
	kind:    wayu.RcKind,
	detail:  string, // GENERATOR: "cmd|args"; PATH/FPATH: "pre|post" (comma-joined); ALIAS/ENV: "name=value"
}

@(private = "file")
opt_ctx :: proc(shell: wayu.ShellType, known: []string = nil, interactive := true) -> wayu.RcContext {
	return wayu.RcContext{shell = shell, interactive = interactive, known_vars = known}
}

@(private = "file")
opt_detail :: proc(c: wayu.RcClass) -> string {
	#partial switch c.kind {
	case .GENERATOR: return fmt.tprintf("%s|%s", c.cmd, c.args)
	case .PATH, .FPATH:
		return fmt.tprintf("%s|%s", strings.join(c.prepend, ",", context.temp_allocator), strings.join(c.appends, ",", context.temp_allocator))
	case .ALIAS, .ENV: return fmt.tprintf("%s=%s", c.name, c.value)
	}
	return ""
}

@(test)
test_optimize_classifier_table :: proc(t: ^testing.T) {
	cases := []OptCase{
		// Generators (zsh/bash): installer completion / init lines.
		{"source <(ng completion script)", .ZSH, .GENERATOR, "ng|completion script"},
		{"source <(grok completion zsh)", .ZSH, .GENERATOR, "grok|completion zsh"},
		{". <(opencode completion)", .ZSH, .GENERATOR, "opencode|completion"},
		{"  source <(kubectl completion zsh)   # kubectl", .ZSH, .GENERATOR, "kubectl|completion zsh"},
		{`eval "$(starship init zsh)"`, .ZSH, .GENERATOR, "starship|init zsh"},
		{`eval "$(zoxide init zsh --cmd cd)"`, .ZSH, .GENERATOR, "zoxide|init zsh --cmd cd"},
		{`eval "$(brew shellenv)"`, .ZSH, .GENERATOR, "brew|shellenv"},
		{`eval "$(pyenv init -)"`, .ZSH, .GENERATOR, "pyenv|init -"},
		{`eval "$(pyenv virtualenv-init -)"`, .ZSH, .GENERATOR, "pyenv|virtualenv-init -"},
		{`eval "$(conda shell.zsh hook 2>/dev/null)"`, .ZSH, .GENERATOR, "conda|shell.zsh hook"},
		{`eval "$(direnv hook zsh)"`, .ZSH, .GENERATOR, "direnv|hook zsh"},
		{`eval "$(mise activate zsh)"`, .ZSH, .GENERATOR, "mise|activate zsh"},
		{"source <(kubectl completion bash)", .BASH, .GENERATOR, "kubectl|completion bash"},
		{`eval "$(/opt/homebrew/bin/brew shellenv)"`, .ZSH, .KEEP, ""},
		{"eval $(thefuck --alias)", .ZSH, .KEEP, ""},
		{`eval "$(fnm env --use-on-cd)"`, .ZSH, .KEEP, ""},
		{`eval "$(wayu export --eval)"`, .ZSH, .KEEP, ""},
		{"source <(cmd init $(other))", .ZSH, .KEEP, ""},
		{"source <(tool completion zsh | sed s/a/b/)", .ZSH, .KEEP, ""},
		{"# source <(kubectl completion zsh)", .ZSH, .KEEP, ""},
		{"source ~/.nvm/nvm.sh", .ZSH, .KEEP, ""},
		{`[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"`, .ZSH, .KEEP, ""},
		{`[[ -x /usr/bin/zoxide ]] && eval "$(zoxide init zsh)"`, .ZSH, .KEEP, ""},
		{`source "${WAYU_DATA_DIR:-$HOME/.local/share/wayu}/init.zsh"`, .ZSH, .KEEP, ""},
		// fpath (zsh only)
		{"fpath=(~/.grok/completions/zsh $fpath)", .ZSH, .FPATH, "$HOME/.grok/completions/zsh|"},
		{`fpath=($HOME/.docker/completions "${fpath[@]}")`, .ZSH, .FPATH, "$HOME/.docker/completions|"},
		{"fpath=($fpath /opt/x/share/zsh)", .ZSH, .FPATH, "|/opt/x/share/zsh"},
		{"fpath+=(/opt/x/completions)", .ZSH, .FPATH, "|/opt/x/completions"},
		{"fpath+=/opt/y/completions", .ZSH, .FPATH, "|/opt/y/completions"},
		{"fpath=(/only/this)", .ZSH, .KEEP, ""},
		{"fpath=(~/.x $fpath)", .BASH, .KEEP, ""},
		// compinit (zsh only)
		{"autoload -Uz compinit && compinit", .ZSH, .COMPINIT, ""},
		{"autoload -U compinit; compinit -C", .ZSH, .COMPINIT, ""},
		{"compinit -i -d ~/.zcompdump", .ZSH, .COMPINIT, ""},
		{"autoload -Uz compinit", .ZSH, .COMPINIT, ""},
		{"autoload -U +X bashcompinit && bashcompinit", .ZSH, .KEEP, ""},
		{"autoload -Uz compinit && compinit && echo done", .ZSH, .KEEP, ""},
		{"compinit", .BASH, .KEEP, ""},
		// PATH
		{`export PATH="$HOME/.grok/bin:$PATH"`, .ZSH, .PATH, "$HOME/.grok/bin|"},
		{"export PATH=$PATH:$HOME/.lmstudio/bin", .ZSH, .PATH, "|$HOME/.lmstudio/bin"},
		{`PATH="/opt/a/bin:/opt/b/bin:$PATH"`, .BASH, .PATH, "/opt/a/bin,/opt/b/bin|"},
		{`export PATH="${PATH}:/opt/c"`, .BASH, .PATH, "|/opt/c"},
		{"path=(~/bin $path)", .ZSH, .PATH, "$HOME/bin|"},
		{"export PATH=/usr/bin:/bin", .ZSH, .KEEP, ""},
		{`export PATH="$(go env GOPATH)/bin:$PATH"`, .ZSH, .KEEP, ""},
		{`export PATH="$BUN_INSTALL/bin:$PATH"`, .ZSH, .KEEP, ""},
		{`export PATH=":$PATH"`, .ZSH, .KEEP, ""},
		// Aliases
		{"alias ll='ls -la'", .ZSH, .ALIAS, "ll=ls -la"},
		{`alias gs="git status"`, .BASH, .ALIAS, "gs=git status"},
		{`alias h=htop`, .ZSH, .ALIAS, "h=htop"},
		{`alias x="cd $HOME"`, .ZSH, .KEEP, ""},
		{"alias -g G='| grep'", .ZSH, .KEEP, ""},
		{"alias a=b c=d", .ZSH, .KEEP, ""},
		{"alias", .ZSH, .KEEP, ""},
		// Constants
		{"export EDITOR=nvim", .ZSH, .ENV, "EDITOR=nvim"},
		{"export GOPATH=~/go", .ZSH, .ENV, "GOPATH=$HOME/go"},
		{`export NVM_DIR="$HOME/.nvm"`, .ZSH, .ENV, "NVM_DIR=$HOME/.nvm"},
		{`export X='$HOME'`, .ZSH, .KEEP, ""},
		{`export X="$(date)"`, .ZSH, .KEEP, ""},
		{"export WAYU_DATA_DIR=/x", .ZSH, .KEEP, ""},
		{"export ZDOTDIR=$HOME/.config/zsh", .ZSH, .KEEP, ""},
		{"export A=1 B=2", .ZSH, .KEEP, ""},
		{"export EDITOR", .ZSH, .KEEP, ""},
		{"EDITOR=vim", .ZSH, .KEEP, ""},
		{"if true; then export X=1; fi", .ZSH, .KEEP, ""},
		// fish
		{"zoxide init fish | source", .FISH, .GENERATOR, "zoxide|init fish"},
		{"starship init fish | source", .FISH, .GENERATOR, "starship|init fish"},
		{"set -gx EDITOR nvim", .FISH, .ENV, "EDITOR=nvim"},
		{"set -Ux EDITOR nvim", .FISH, .KEEP, ""},
		{"set -g fish_greeting", .FISH, .KEEP, ""},
		{"set -gx PATH $HOME/.cargo/bin $PATH", .FISH, .PATH, "$HOME/.cargo/bin|"},
		{"fish_add_path ~/.local/bin", .FISH, .PATH, "$HOME/.local/bin|"},
		{"fish_add_path -a /opt/x/bin", .FISH, .PATH, "|/opt/x/bin"},
		{"alias ll 'ls -la'", .FISH, .ALIAS, "ll=ls -la"},
		{"alias ll='ls -la'", .FISH, .ALIAS, "ll=ls -la"},
		{"if status is-interactive; zoxide init fish | source; end", .FISH, .KEEP, ""},
	}
	for c in cases {
		got := wayu.rc_classify_line(c.line, opt_ctx(c.shell))
		if !testing.expectf(t, got.kind == c.kind, "%q (%v): kind %v, want %v (reason: %s)", c.line, c.shell, got.kind, c.kind, got.reason) {
			continue
		}
		if c.kind != .KEEP && len(c.detail) > 0 {
			testing.expectf(t, opt_detail(got) == c.detail, "%q: %q, want %q", c.line, opt_detail(got), c.detail)
		}
	}
	free_all(context.temp_allocator)
}

@(test)
test_optimize_classifier_context :: proc(t: ^testing.T) {
	// Generators only move from the interactive rc file.
	c := wayu.rc_classify_line("source <(ng completion script)", opt_ctx(.ZSH, interactive = false))
	testing.expect_value(t, c.kind, wayu.RcKind.KEEP)
	// A variable wayu defines may be referenced.
	known := []string{"BUN_INSTALL"}
	c = wayu.rc_classify_line(`export PATH="$BUN_INSTALL/bin:$PATH"`, opt_ctx(.ZSH, known))
	testing.expect_value(t, c.kind, wayu.RcKind.PATH)
	testing.expect_value(t, opt_detail(c), "$BUN_INSTALL/bin|")
	// Secret-looking constants are marked secret; with variables they stay.
	c = wayu.rc_classify_line("export OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz0123456789", opt_ctx(.ZSH))
	testing.expect_value(t, c.kind, wayu.RcKind.ENV)
	testing.expect(t, c.secret, "API key is secret")
	c = wayu.rc_classify_line(`export GITHUB_TOKEN="$HOME/x"`, opt_ctx(.ZSH))
	testing.expect_value(t, c.kind, wayu.RcKind.KEEP)
	free_all(context.temp_allocator)
}

@(test)
test_optimize_scan_blocks_and_loader :: proc(t: ^testing.T) {
	content := `export EARLY=1
source "${WAYU_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/wayu}/init.zsh"
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"
if [[ -f ~/.x ]]; then
  export INSIDE=1
  alias inside=yes
fi
foo() {
  export IN_FUNC=1
}
case $OSTYPE in
  darwin*) alias open1=open ;;
  linux*)
    alias open2=xdg-open
    ;;
esac
for f in a b; do
  export LOOPED=1
done
# >>> conda initialize >>>
__conda_setup="$('/opt/conda/bin/conda' 'shell.zsh' 'hook' 2> /dev/null)"
if [ $? -eq 0 ]; then
    eval "$__conda_setup"
fi
unset __conda_setup
# <<< conda initialize <<<
export PATH="$HOME/a:\
$PATH"
alias after=yes
`
	ctx := opt_ctx(.ZSH)
	findings, loaded := wayu.rc_scan_content(content, &ctx, false)
	testing.expect(t, loaded, "loader found")
	names := make([dynamic]string, context.temp_allocator)
	for f in findings {
		append(&names, fmt.tprintf("%d-%d:%v:%s", f.first_line, f.last_line, f.class.kind, opt_detail(f.class)))
	}
	want := []string{
		"3-3:ENV:BUN_INSTALL=$HOME/.bun",
		"4-4:PATH:$BUN_INSTALL/bin|",
		"28-29:PATH:$HOME/a|",
		"30-30:ALIAS:after=yes",
	}
	testing.expectf(t, len(names) == len(want), "findings %v, want %v", names[:], want)
	for w, i in want {
		if i < len(names) { testing.expect_value(t, names[i], w) }
	}

	// Nothing before the loader moves; without a loader nothing moves.
	ctx2 := opt_ctx(.ZSH)
	f2, l2 := wayu.rc_scan_content("export EDITOR=nvim\nalias ll=ls\n", &ctx2, false)
	testing.expect(t, !l2, "no loader")
	testing.expect_value(t, len(f2), 0)
	// A file after the loader's file: everything top-level is a candidate.
	f3, _ := wayu.rc_scan_content("export EDITOR=nvim\n", &ctx2, true)
	testing.expect_value(t, len(f3), 1)
	// An unreadable statement (here-document) stops the scan.
	f4, _ := wayu.rc_scan_content("alias a=b\ncat <<EOF\nalias x=y\nEOF\nalias c=d\n", &ctx2, true)
	testing.expect_value(t, len(f4), 1)
	free_all(context.temp_allocator)
}

@(test)
test_optimize_scan_fish_blocks :: proc(t: ^testing.T) {
	content := `if status is-interactive
    starship init fish | source
else if test -n "$X"
    set -gx IN_ELSE 1
end
function f
    set -gx IN_FUNC 1
end
zoxide init fish | source
set -gx EDITOR nvim
`
	ctx := opt_ctx(.FISH)
	findings, _ := wayu.rc_scan_content(content, &ctx, true)
	testing.expect_value(t, len(findings), 2)
	if len(findings) == 2 {
		testing.expect_value(t, findings[0].first_line, 9)
		testing.expect_value(t, findings[1].class.kind, wayu.RcKind.ENV)
	}
	free_all(context.temp_allocator)
}

@(test)
test_optimize_merge_dirs_order :: proc(t: ^testing.T) {
	keep :: proc(d: []string) -> []string {
		out := make([]string, len(d), context.temp_allocator)
		copy(out, d)
		return out
	}
	pre :: proc(d: ..string) -> wayu.RcClass { return wayu.RcClass{kind = .PATH, prepend = keep(d)} }
	app :: proc(d: ..string) -> wayu.RcClass { return wayu.RcClass{kind = .PATH, appends = keep(d)} }
	join :: proc(l: []string) -> string { return strings.join(l, ",", context.temp_allocator) }

	// Later prepends end up further in front, ahead of wayu's own dirs.
	out, ch := wayu.optimize_merge_dirs({"/w1", "/w2"}, {pre("/a"), pre("/b")})
	testing.expect(t, ch, "changed")
	testing.expect_value(t, join(out), "/b,/a,/w1,/w2")
	// One line's dirs keep their order.
	out, _ = wayu.optimize_merge_dirs({"/w1"}, {pre("/a", "/b")})
	testing.expect_value(t, join(out), "/a,/b,/w1")
	// Prepending a wayu dir moves it to the front.
	out, _ = wayu.optimize_merge_dirs({"/w1", "/w2"}, {pre("/w2")})
	testing.expect_value(t, join(out), "/w2,/w1")
	// Appending a listed dir changes nothing; a new one goes last.
	out, ch = wayu.optimize_merge_dirs({"/w1", "/w2"}, {app("/w1")})
	testing.expect(t, !ch, "append of a present dir is a no-op")
	out, _ = wayu.optimize_merge_dirs({"/w1"}, {app("/c"), pre("/a")})
	testing.expect_value(t, join(out), "/a,/w1,/c")
	// `~/x` and `$HOME/x` are the same entry.
	out, ch = wayu.optimize_merge_dirs({"~/bin"}, {pre("$HOME/bin")})
	testing.expect(t, !ch, "same dir")
	free_all(context.temp_allocator)
}

@(test)
test_entries_fpath_generators_round_trip :: proc(t: ^testing.T) {
	store := wayu.EntryStore{version = wayu.ENTRIES_FORMAT_VERSION}
	defer wayu.entries_store_destroy(&store)
	append(&store.fpath, strings.clone("$HOME/.grok/completions/zsh"))
	append(&store.generators, wayu.StoreGenerator{strings.clone("zsh"), strings.clone("ng"), strings.clone("completion script")})
	text := wayu.entries_serialize(&store)
	defer delete(text)
	back, err, ok := wayu.entries_parse(text)
	defer wayu.entries_store_destroy(&back)
	testing.expectf(t, ok, "parse: %s\n%s", err, text)
	testing.expect_value(t, len(back.fpath), 1)
	testing.expect_value(t, len(back.generators), 1)
	if len(back.generators) == 1 { testing.expect_value(t, back.generators[0].args, "completion script") }

	// Empty sections are not written (unchanged files for existing stores).
	empty := wayu.EntryStore{version = wayu.ENTRIES_FORMAT_VERSION}
	et := wayu.entries_serialize(&empty)
	defer delete(et)
	testing.expect(t, !strings.contains(et, "fpath") && !strings.contains(et, "generators"), "no empty sections")

	// Strict: a bad shell or duplicate is a config error.
	_, e1, ok1 := wayu.entries_parse(`{"version": 1, "generators": [{"shell": "tcsh", "cmd": "x", "args": "init"}]}`)
	testing.expectf(t, !ok1, "bad shell rejected (%s)", e1)
	_, _, ok2 := wayu.entries_parse(`{"version": 1, "fpath": ["/a", "/a"]}`)
	testing.expect(t, !ok2, "duplicate fpath rejected")
	_, _, ok3 := wayu.entries_parse(`{"version": 1, "generators": [{"shell": "zsh", "cmd": "a b", "args": ""}]}`)
	testing.expect(t, !ok3, "bad cmd rejected")
	free_all(context.temp_allocator)
}

@(test)
test_optimize_new_content_and_diff :: proc(t: ^testing.T) {
	content := "a\nb\nalias x=y\nc\n"
	f := wayu.OptimizeFile{
		path = "/tmp/rc",
		content = content,
		findings = []wayu.RcFinding{{3, 3, wayu.RcClass{kind = .ALIAS, name = "x", value = "y"}}},
	}
	testing.expect_value(t, wayu.optimize_new_content(f), "a\nb\nc\n")
	d := wayu.optimize_file_diff(f)
	testing.expectf(t, strings.contains(d, "@@ -1,4 +1,3 @@") && strings.contains(d, "-alias x=y") && strings.contains(d, " c"), "diff:\n%s", d)
	free_all(context.temp_allocator)
}

@(test)
test_config_scan_detects_marked_blocks :: proc(t: ^testing.T) {
	content := `# >>> conda initialize >>>
# !! Contents within this block are managed by 'conda init' !!
__conda_setup="$('/opt/conda/bin/conda' 'shell.zsh' 'hook' 2> /dev/null)"

unset __conda_setup
# <<< conda initialize <<<

alias ll='ls -la'
`
	blocks := wayu.detect_rc_script_blocks_in(content)
	defer {
		for b in blocks { delete(b) }
		delete(blocks)
	}
	testing.expect_value(t, len(blocks), 2)
	if len(blocks) == 2 {
		testing.expect_value(t, len(blocks[0]), 6)
		testing.expect_value(t, blocks[1][0], "alias ll='ls -la'")
	}
}

@(test)
test_backup_name_resolves_startup_files :: proc(t: ^testing.T) {
	home := os.get_env("HOME", context.temp_allocator)
	p := wayu.startup_file_for_backup_name(".bashrc")
	defer if len(p) > 0 { delete(p) }
	testing.expect_value(t, p, fmt.tprintf("%s/.bashrc", home))
	r := wayu.startup_file_for_backup_name(fmt.tprintf("%s/.profile", home))
	defer if len(r) > 0 { delete(r) }
	testing.expect_value(t, r, fmt.tprintf("%s/.profile", home))
	q := wayu.startup_file_for_backup_name("wayu.toml")
	testing.expect_value(t, q, "")
	free_all(context.temp_allocator)
}
