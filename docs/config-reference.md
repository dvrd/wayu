# wayu configuration reference

Everything wayu reads: `wayu.toml` (every table and key), what wayu manages
for you (`entries.json`: PATH entries, aliases, constants; `functions/`,
`scripts/`, `completions/`), the other files you may edit (`hooks.conf`,
`plugins.json`, `extra.<ext>`, `tools.<ext>`, `alias-sources.conf`), where
they live, and which files are generated.

- Commands and flags: [cli.md](cli.md).
- Behavior changes between versions: [UPGRADING.md](UPGRADING.md).

`<ext>` below is the shell's extension: `zsh`, `bash` or `fish`.

## Contents

- [Directories](#directories)
- [wayu.toml](#wayutoml)
  - [Complete example](#complete-example)
  - [TOML syntax wayu accepts](#toml-syntax-wayu-accepts)
  - [Strict and lenient reading](#strict-and-lenient-reading)
  - [`[shell]`](#shell)
  - [`[settings]`](#settings)
  - [`[tools]`](#tools)
  - [`[prompt]`](#prompt)
  - [`[scripts]`](#scripts)
  - [`[secrets]`](#secrets)
  - [Keys wayu does not read](#keys-wayu-does-not-read)
- [Managed data](#managed-data)
  - [entries.json](#entriesjson)
  - [PATH entries](#path-entries)
  - [Aliases](#aliases)
  - [Constants](#constants)
- [Other files you edit](#other-files-you-edit)
  - [hooks.conf](#hooksconf)
  - [plugins.json](#pluginsjson)
  - [extra.\<ext\> and tools.\<ext\>](#extraext-and-toolsext)
  - [config.\<ext\>](#configext)
  - [functions/](#functions)
  - [scripts/ and bin/](#scripts-and-bin)
  - [completions/](#completions)
  - [alias-sources.conf](#alias-sourcesconf)
- [Generated files](#generated-files)
- [Load order](#load-order)

## Directories

| Variable | Default | Holds |
|---|---|---|
| `WAYU_CONFIG_DIR` | `~/.config/wayu` | Files you edit: `wayu.toml`, `hooks.conf`, `alias-sources.conf`, `extra.<ext>`, `tools.<ext>`, `config.<ext>` |
| `WAYU_DATA_DIR` | `${XDG_DATA_HOME:-~/.local/share}/wayu` | Data wayu manages: `entries.json`, `plugins.json`, `functions/` (`wayu function`), `scripts/` and `bin/` (`wayu script`), and generated / runtime files: `init.<ext>`, `core.<ext>`, `path_sync.<ext>`, `turbo.<ext>`, `plugins.<ext>`, `plugins/`, `completions/`, `backup/`, `.wayu.lock` |

- Each variable is read independently: setting one never moves the other.
  `wayu init` creates both dirs; the first command that writes creates the
  data dir if it is missing.
- `WAYU_CONFIG_DIR` and `WAYU_DATA_DIR` must be absolute paths: a relative one
  makes every command exit `78`. A relative `XDG_DATA_HOME` is ignored (XDG
  spec), so the data dir is then `~/.local/share/wayu`.
- The rc line `wayu init` adds finds the data dir by itself:

  ```sh
  source "${WAYU_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/wayu}/init.zsh"
  ```

- `init.<ext>` finds its files next to itself, so that line works without
  exporting either variable to the shell. If `WAYU_CONFIG_DIR` is unset, the
  config dir is `~/.config/wayu`.
- When either dir differs from the default, `core.<ext>` exports
  `WAYU_CONFIG_DIR` / `WAYU_DATA_DIR`, so `wayu` commands typed in that shell
  use the same dirs.
- The `[tools]` evalcache lives outside both:
  `${XDG_CACHE_HOME:-~/.cache}/wayu/evalcache` (`wayu build clean` deletes it).

## wayu.toml

`$WAYU_CONFIG_DIR/wayu.toml` is the file you edit for `[shell]`,
`[settings]`, `[tools]` loaders and the native `[prompt]`. PATH entries,
aliases and constants are not in it: wayu manages them in
[`entries.json`](#managed-data) through `wayu path|alias|const`. `wayu init`
creates this scaffold:

```toml
[shell]
type = "zsh"
```

After editing it by hand, run `wayu build`; changes apply to new shells.
`wayu toml validate` checks the file (see
[Strict and lenient reading](#strict-and-lenient-reading)).

### Complete example

This file passes `wayu toml validate` and `wayu build` as-is.

```toml
[shell]
type = "zsh"

[settings]
autosuggestions_accept_keys = [
  "^Y",
  "^[[121;5u",
]

[tools]
zoxide = { kind = "evalcache", args = "init zsh" }
atuin  = { args = "init zsh --disable-up-arrow", eager = true }
nvm    = { kind = "nvm" }
sdk    = { kind = "lazy", init_script = "~/.sdkman/bin/sdkman-init.sh", hook_commands = ["sdk"] }
keychain = { args = "--eval --quiet id_ed25519", login_only = true }

[prompt]
enabled = true
vi_mode = false
format  = "{username}{dir}{git_branch}[{language_context}](yellow){character} "

[prompt.username]
show_always = true
format = "[$user](white bold) in "

[prompt.dir]
format = "[$dir](cyan bold) "

[prompt.git_branch]
format = "on [$branch](magenta bold) "

[prompt.character]
success_symbol = "[>](green)"
error_symbol   = "[x](red)"

[prompt.contexts]
rust   = { format = "rs $version ", detect = ["Cargo.toml"] }
kotlin = { format = "kt ", detect = ["*.kt", "build.gradle.kts"] }

[prompt.interactive]
toggle_enabled = true
toggle_key = "^G"
vi_mode_indicator = true
async_rprompt = true
rprompt_format = "[ {git_pending}](242)"
```

What it generates in `core.zsh` together with the
[entries.json example](#entriesjson) (excerpt):

```zsh
export GOBIN="${GOPATH}/bin"
export PAGER_OPTS="${LESS:--R}"
export PRICE="costs \$5"
_wayu_paths_apply <sig> ${HOME:+"${HOME}"'/.local/bin'} ${HOME:+"${HOME}"'/.cargo/bin'} ${GOPATH:+"${GOPATH}"'/bin'} '/opt/homebrew/bin'
_wayu_evalcache atuin init zsh --disable-up-arrow     # eager section
_wayu_evalcache zoxide init zsh                       # deferred section
if [[ -o login ]]; then
_wayu_evalcache keychain --eval --quiet id_ed25519
fi
alias onlead-logs='tail -f /var/log/onlead.log'
```

### TOML syntax wayu accepts

wayu uses one TOML 1.0 parser for every command (plus the TOML 1.1
conveniences `\e`, `\xHH`, and newlines / trailing commas in inline tables).
A UTF-8 BOM, comments, dotted keys, quoted keys, multi-line arrays, floats and
dates are all accepted.

Arrays and inline tables are valid only where a key below says so:
`[settings] autosuggestions_accept_keys`, `[tools]` entries and their
`hook_commands`, and `[prompt.contexts]` entries.

Keys:

- A bare key may use `A-Z a-z 0-9 _ -`. Anything else needs quotes:
  `"my key" = ...`. Quoted keys are decoded everywhere (`"q\"k"` is the name
  `q"k`).
- wayu writes `wayu.toml` only when it creates it (`wayu init`, or a command
  that needs a missing one); after that the file is yours.

### Strict and lenient reading

| Reader | On a syntax error |
|---|---|
| `wayu toml validate`, `wayu doctor`, `wayu backup restore` (strict) | Fail and name the line: `Failed to parse <file>: line 5: invalid value "ls" (strings must be quoted)` |
| Everything else: the generator (`wayu build`, every write), the TUI (lenient) | Use what was recovered; a line that is not valid TOML is skipped |

Strict-only failures: a key defined twice in one table, a table defined twice,
an integer with leading zeros (`007`), an unquoted string.

After parsing, `wayu toml validate` also checks:

| Check | Error |
|---|---|
| Top-level `version`, if present, is `"1.0"` | `Unsupported config version: 2.0` |
| `[shell] type` (case-insensitive) is zsh, bash or fish | `Invalid shell: unknown (must be zsh, bash, or fish)` |
| No `[paths]`, `[aliases]` or `[env]` (in any form): those entries live in `entries.json` | `Validation failed: line 4: [env] is not read from wayu.toml: its entries are managed with 'wayu const add' (stored in <data>/entries.json); move them there and delete the table` |
| `shell`, `settings`, `tools`, `prompt` are tables (`[tools]`, not `[[tools]]` or `tools = ...`) | `Validation failed: line 1: [[tools]]: tools must be a table ([tools]), not an array of tables` |

Keys and tables wayu does not read are warnings, not errors (see [Keys wayu
does not read](#keys-wayu-does-not-read)).

It does not check `[tools]` args (`wayu build` does) or `[prompt]`. Exit
status: `0` valid, `65` invalid, `78` before `wayu init`.

### `[shell]`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `type` | string | `"zsh"` | `zsh`, `bash` or `fish` (case-insensitive). Written lowercase by `wayu init` and any command that creates a missing `wayu.toml`. |

`type` is a record of the shell the config was set up for and is checked by
`toml validate`; it does not choose the shell. wayu acts for the shell named
by `--shell`, else `$SHELL`, and regenerates the files of every other shell
already initialized in the data dir (`init.<ext>` or `core.<ext>` exists). A
top-level `shell = "..."` string is not read (`toml validate` rejects it).

### `[settings]`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `autosuggest` | boolean | `false` | zsh only (interactive). Built-in fish-like suggestions from history, in place of the zsh-autosuggestions plugin: see [Autosuggestions](#autosuggestions). A non-boolean value is an error (`toml validate`, `doctor`). |
| `autosuggest_style` | string | `"fg=8"` | zsh only. How the suggestion is drawn: a `region_highlight` spec (`fg=244`, `fg=8,underline`; one line, at most 64 bytes, else an error). |
| `autosuggestions_accept_keys` | array of strings | `["^Y", "^[[121;5u"]` | zsh only. Key sequences that accept the whole suggestion: bound to `autosuggest-accept` (zsh-autosuggestions) in the `main`, `emacs` and `viins` keymaps, or, with `autosuggest = true`, to `wayu-suggest-accept` in `emacs` and `viins`. Entries must start with `^` or contain `[`; others, non-strings, empties and duplicates are ignored. An empty or missing array uses the default. The array may span lines. |
| `auto_optimize` | boolean | `false` | When an open shell notices that a startup file changed (prompt hook) and it has lines `wayu optimize` can move, move them right away (backups first) and print what moved, instead of printing the `wayu: ~/.zshrc changed: N lines can be optimized` notice. |

| `compinit_guard` | boolean | `true` | zsh only. After wayu's `compinit`, `compinit` is a function that only registers the completions (`#compdef` / `#autoload` files) of `fpath` dirs added since; its flags (`-C`, `-i`, `-u`, `-d <dump>`, ...) are accepted and ignored. An installer's `autoload -Uz compinit && compinit` in `.zshrc` then costs a glob of the new dirs instead of a second full completion setup (audit, dump check/rewrite), and its dirs' completions work even with `-C`. The same registration runs once at the first prompt, for dirs added to `fpath` without a `compinit` call. `false`: later `compinit` calls are zsh's own. |
| `defer_plugins` | boolean | `false` | zsh only. Load the plugins (`plugins.zsh`, `plugins/config.zsh`) after the first prompt is drawn (through zsh-defer) instead of during startup. They then load after `tools.zsh` / `extra.zsh`: code there that needs a plugin widget should run through `zsh-defer`. |
| `highlight` | boolean | `false` | zsh only (interactive). Built-in syntax highlighting of the command line, in place of the zsh-syntax-highlighting / fast-syntax-highlighting plugins: see [Syntax highlighting](#syntax-highlighting). A non-boolean value is an error. |
| `highlight_styles` | table of strings | see [styles](#syntax-highlighting) | zsh only. Per-style `region_highlight` specs, as an inline table (`highlight_styles = { command = "fg=blue", comment = "fg=244" }`) or a `[settings.highlight_styles]` table. `"none"`: not highlighted. A value that isn't a one-line string of at most 64 bytes is an error; an unknown style name is a warning (ignored). |
| `lazy_compinit` | boolean | `false` | zsh only. No `compinit` at startup: the completion widgets (Tab, `^D` list, ...) set up completion on first use and then complete. `compdef` calls made before that are queued and replayed. `$_comps` and completion functions don't exist until then. |

The plugin bindings are written to `<data>/plugins/config.zsh`, which
`core.zsh` sources after the plugins; they apply only when the
`autosuggest-accept` widget exists. No other `[settings]` key is read.

#### Autosuggestions

`autosuggest = true` puts suggestions in `core.zsh` itself (interactive zsh;
nothing forks, no extra files). As you type, the newest history entry
that starts with the line (typed glob characters are literal) is shown after
the cursor in `autosuggest_style`. It is computed in a `zle-line-pre-redraw`
hook (`add-zle-hook-widget`, which zsh-syntax-highlighting 0.8+ also uses)
instead of wrapping every widget at the first prompt and before every prompt
as the zsh-autosuggestions plugin does.

- Accept all: `forward-char`, `end-of-line`, `vi-forward-char`,
  `vi-end-of-line`, `vi-add-eol` (→, `^F`, `^E`/End where bound, vi `l`
  `$` `A`) with the cursor at the end of the line, and the
  `autosuggestions_accept_keys` (default `^Y`).
- Accept part: `forward-word`, `emacs-forward-word`, `vi-forward-word`,
  `vi-forward-word-end`, `vi-forward-blank-word`, `vi-forward-blank-word-end`,
  `vi-find-next-char`, `vi-find-next-char-skip` (`M-f`, vi `w` `e` `W` `E`
  `f` `t`) move through the suggestion and take what ends up before the
  cursor.
- Only these 13 widgets are wrapped (chaining to what was bound before);
  the suggestion is gone when the cursor isn't at the end, after history
  and search widgets (the line already came from history) and once the line
  is accepted: Enter runs only what you typed.
- With `autosuggest = true` the zsh-autosuggestions plugin is not loaded,
  even if installed and enabled (`wayu doctor` warns until it is removed or
  disabled). `defer_plugins` / `lazy_compinit` don't affect it (it is set up
  at startup; it is cheap). bash and fish ignore it (`doctor` notes it).
- Suggestions come from history (most recent match); a multi-line history
  entry is suggested whole. When nothing in history matches and the line is
  a single word, the shortest command name on `PATH` starting with it is
  suggested (ties: alphabetical), e.g. `no` → `node` if no `no…` command is
  shorter. No completion strategy beyond that.

#### Syntax highlighting

`highlight = true` puts a syntax highlighter in `core.zsh` itself
(interactive zsh; nothing forks, no extra files, no widget is wrapped).
It runs in a `zle-line-pre-redraw` hook, like the autosuggestions: zsh's own
lexer (`${(z)BUFFER}`) splits the line into words, which are colored by
`region_highlight` entries (tagged `memo=wayu-highlight` on zsh 5.9+; other
entries, such as the suggestion's or your own, are kept). The line is only
looked at again when it changed, and an edit anywhere in it re-highlights
from the word before the change until the words after it are back in the
state they had (usually a word or two), not the whole line. Lines already
entered at a continuation prompt (PS2) are highlighted with the current one,
so its words keep their meaning. Command lookups and path checks are cached
until a command runs or the directory / `PATH` changes.

The style names are zsh-syntax-highlighting's (its `ZSH_HIGHLIGHT_STYLES`
values carry over) and so are the defaults:

| Style | Default | What |
|---|---|---|
| `unknown-token` | `fg=red,bold` | a command that doesn't exist (yet) |
| `reserved-word` | `fg=yellow` | `if` `then` `for` `do` `case` `in` `always` `[[` `]]` `{` `}` `((` `))` `(` `)` `!`, case pattern parentheses ... |
| `alias` | `fg=green` | an alias |
| `suffix-alias` | `fg=green,underline` | a file run through a suffix alias (`alias -s`) |
| `global-alias` | `fg=cyan` | a global alias (`alias -g`), anywhere on the line |
| `builtin` | `fg=green` | a builtin (`typeset` & co. too) |
| `function` | `fg=green` | a function |
| `command` | `fg=green` | a command on `PATH`, or an executable path |
| `precommand` | `fg=green,underline` | `sudo` `doas` `env` `command` `builtin` `exec` `noglob` `nocorrect` `time` `nohup` `nice` `-`: the next word is a command again (after their options; `sudo -u user`, `env -u NAME`, `env NAME=value` are understood) |
| `commandseparator` | none | `;` `&&` `\|\|` `\|` `\|&` `&` `;;`, newline |
| `autodirectory` | `fg=green,underline` | a directory in command position, with `setopt autocd` |
| `path` | `underline` | an existing file or directory (`~` and `~name` expanded) |
| `path_prefix` | `underline` | the last word, while it is the start of an existing name |
| `globbing` | `fg=blue` | a word with unquoted `*` `?` `[...]` |
| `expansion` | `fg=cyan` | `$var` `${...}` `$((...))` outside double quotes (wayu's; zsh-syntax-highlighting leaves them plain) |
| `command-substitution-delimiter` | `fg=magenta` | `$(` and `)`; the inside is highlighted as a command line |
| `process-substitution-delimiter` | `fg=magenta` | `<(` `>(` `=(` and `)` |
| `back-quoted-argument-delimiter` | `fg=magenta` | the backticks of `` `...` `` |
| `single-hyphen-option` | none | `-x` |
| `double-hyphen-option` | none | `--long` |
| `single-quoted-argument` | `fg=yellow` | `'...'` (to the end while unterminated) |
| `double-quoted-argument` | `fg=yellow` | `"..."` (to the end while unterminated) |
| `dollar-quoted-argument` | `fg=yellow` | `$'...'` |
| `dollar-double-quoted-argument` | `fg=cyan` | `$var` `${...}` `$((...))` inside `"..."` |
| `back-double-quoted-argument` | `fg=cyan` | `\"` `\$` `` \` `` `\\` inside `"..."` |
| `back-dollar-quoted-argument` | `fg=cyan` | `\n` & co. inside `$'...'` |
| `assign` | none | `NAME=value` before a command or after `typeset` & co. (the value is highlighted too), `name=(` ... `)` |
| `redirection` | `fg=yellow` | `>` `>>` `<` `2>` `&>` `<<<` `>&` `{fd}>` ... |
| `comment` | `fg=black,bold` | `# ...`, with `setopt interactive_comments` |
| `history-expansion` | `fg=blue` | `!!` `!$` `!-2` `!str` ... (with `banghist`; also inside `"..."`, where zsh expands them too) |
| `named-fd` | none | `{fd}` in `{fd}>file` |
| `numeric-fd` | none | the descriptor after `>&` / `<&` (`2>&1`, `>&-`) |
| `bracket-level-1` | `fg=blue,bold` | `(` `)` `[` `]` `{` `}` outside quotes, by nesting depth (levels 1–3, then 1 again) |
| `bracket-level-2` | `fg=green,bold` | |
| `bracket-level-3` | `fg=magenta,bold` | |
| `bracket-error` | `fg=red,bold` | a bracket without its pair (or closed by the wrong one) |
| `cursor-matchingbracket` | `standout` | the pair of the bracket under the cursor |

- Heredoc bodies are skipped; what follows the delimiter line is a command
  line again.
- The selected region, the incremental search match and pasted text keep
  their `zle_highlight` look (default: standout / underline / standout).
- With `highlight = true` the zsh-syntax-highlighting and
  fast-syntax-highlighting plugins are not loaded, even if installed and
  enabled (`wayu doctor` warns until they are removed or disabled).
  `defer_plugins` / `lazy_compinit` don't affect it (it is set up at
  startup; it is cheap). bash and fish ignore it (`doctor` notes it).
- Brackets: `((` `))` of arithmetic, `[[` `]]`, `[` `]` as words, the
  parentheses of case patterns and of `name=(...)` are syntax, not brackets;
  brackets inside `"..."` are not counted.
- After `noglob`, `*` `?` `[...]` are not highlighted as globs; after
  `command -v`, the name is highlighted as a command.
- Not covered (zsh-syntax-highlighting's other highlighters and some main
  ones): `rc-quote`, `hashed-command`, path separators; a line longer than
  20000 characters is not highlighted. `tests/highlight_diff` compares the
  highlighter with fast-syntax-highlighting and lists the intended
  differences.

Interactive-only parts of `core.zsh` (completion, the native prompt,
plugins, zsh-defer) are skipped in non-interactive zsh (`zsh -c`,
scripts): there it sets constants, secrets, PATH entries, `functions/`,
`config.zsh`, `[tools]`, `tools.zsh`, `extra.zsh` and aliases (zsh expands
aliases in `zsh -c` too), and `zsh-defer` is a no-op. Sourcing `init.zsh`
again in a shell (e.g. from both `.zshenv` and `.zshrc`) doesn't reorder
PATH, add wayu's completions dir to `fpath` twice, source an already
loaded plugin again or redo `compinit`.

### `[tools]`

Shell integrations for installed tools, generated into `core.<ext>`:

```toml
[tools]
zoxide   = { kind = "evalcache", args = "init zsh" }
atuin    = { args = "init zsh --disable-up-arrow", eager = true }
nvm      = { kind = "nvm" }
conda    = { kind = "conda" }
sdk      = { kind = "lazy", init_script = "~/.sdkman/bin/sdkman-init.sh", hook_commands = ["sdk"] }
keychain = { args = "--eval --quiet id_ed25519", login_only = true }

[tools.direnv]          # a sub-table works too
args = "hook zsh"
```

Each entry is an inline table or a `[tools.<name>]` sub-table; other values
are ignored. Entries are emitted in file order (an entry may rely on one
above it).

| Key | Type | Default | Meaning |
|---|---|---|---|
| `kind` | string | `"evalcache"` | `evalcache`, `nvm`, `conda` or `lazy`. Any other kind is skipped with a `# wayu: unknown kind` comment. |
| `args` | string | `""` | evalcache: arguments for the tool, e.g. `"init zsh"` (rules below). |
| `eager` | boolean | `false` | evalcache only: load before the prompt and plugins (tools that bind keys, e.g. atuin). Ignored for other kinds. |
| `login_only` | boolean | `false` | Load only in login shells (`[[ -o login ]]`, `shopt -q login_shell`, `status is-login`). Wins over `eager`. |
| `init_script` | string | | lazy: script sourced on first use (leading `~` and `$VAR` expand; sourced only when non-empty). |
| `hook_commands` | array of strings | | lazy: commands that trigger the load. |

Booleans must be TOML booleans: `eager = "true"` is ignored.

Kinds:

| Kind | What it generates |
|---|---|
| `evalcache` | Runs `command <name> <args>` (the table key is the binary, looked up in `PATH` only, never a function or alias), caches the output in `${XDG_CACHE_HOME:-~/.cache}/wayu/evalcache` and sources the cache. The cache is rebuilt when the binary changes (zsh: resolved path, size, mtime, inode; bash: path, mtime, inode/target; fish: path, mtime, needs fish 3.5+, else uncached). A tool that is not installed is skipped silently. Run `wayu build clean` when the init output depends on config or the environment. The tool name must be a valid alias name. |
| `nvm` | Lazy NVM: needs `$NVM_DIR` (default `~/.nvm`) to exist. Puts the default node on `PATH` at once; `nvm.sh` is sourced on the first `nvm` call. zsh also wraps `node`, `npm`, `npx`, `corepack` and switches versions on `cd` into a dir with `.nvmrc` / `.node-version`. No fish version (skipped with a comment). |
| `conda` | Lazy conda: finds the first of `~/anaconda3`, `~/miniconda3`, `~/miniforge3`, `/opt/homebrew/anaconda3`, `/opt/anaconda3`; `conda` and `mamba` load it on first call. No fish version (skipped). |
| `lazy` | Defines each `hook_commands` entry as a wrapper that sources `init_script` once, then runs the real command. Needs both keys (else skipped with a comment); entries that are not valid alias names are skipped. In fish, `init_script` must end in `.fish`. |

**`args` rules.** `args` is split into words the way the shell does (single
and double quotes, backslashes) and each word is re-quoted in the generated
call, so it can never run code at startup:

- Expand: `$NAME` / `${NAME...}` (same rules as [constants](#constants)) outside
  single quotes, and a leading `~` / `~/`.
- Literal: everything else, including `{a,b}` (no brace expansion).
- Refused: a newline, `;` `&` `|` `<` `>` `(` `)`, `$(...)`, backticks,
  unquoted glob characters `*` `?` `[`, and a word that mixes quoted and
  unquoted `$`. `wayu build` exits `78` naming the tool
  (`ERROR: wayu.toml [tools] foo: args contains the shell operator ";"`);
  other regenerations skip the tool with a warning on stderr.

For example `args = 'init "$HOME/x y" ~/z {a,b}'` generates
`_wayu_evalcache foo init "${HOME}/x y" "${HOME}/z" '{a,b}'`.

**Shell name in `args`.** One entry serves every shell: a word `zsh` or
`bash` in `args` becomes the shell whose file is generated, and `--zsh` /
`--bash` becomes `--<shell>`. `args = "init zsh"` runs `zoxide init zsh` in
core.zsh, `zoxide init bash` in core.bash and `zoxide init fish` in fish
(`[tools]` load in fish too).

**Where they load** (see [Load order](#load-order)): eager evalcache tools
before the prompt and plugins; all other non-login tools ("deferred") after
the plugins; `login_only` tools after `tools.<ext>` and `extra.<ext>`.
"Deferred" is a position in the file, not a key, and not zsh-defer.

### `[prompt]`

A native prompt for zsh and fish, off by default. It is generated only when
`[prompt] enabled = true`, and set up only in interactive shells. bash
ignores the whole table. fish differences: see [fish](#prompt-in-fish).

The `[prompt]` tables are read with the same TOML parser as the rest of
`wayu.toml`: comments, dotted keys, `[prompt.contexts.<name>]` tables and
multi-line strings work, and a value of the wrong type keeps the default.

#### `[prompt]`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `enabled` | boolean | `false` | Generate the prompt. Without it wayu leaves `PROMPT`, keymaps and zle widgets alone. |
| `vi_mode` | boolean | `false` | `bindkey -v`, `KEYTIMEOUT=1` (not exported), and the mode indicator unless `[prompt.interactive] vi_mode_indicator = false`. Without it the keymap is left alone and `{character}` shows success/error by exit status. |
| `format` | string | `"{username}{dir}{git_branch}{character} "` | Prompt layout. `\n` starts a new line. |

`format` tokens (unknown tokens produce nothing; other text is literal):

| Token | Shows |
|---|---|
| `{username}` | `[prompt.username] format` |
| `{hostname}` | `[prompt.hostname] format` |
| `{localip}` | `[prompt.localip] format` |
| `{dir}` | `[prompt.dir] format` |
| `{git_branch}` | `[prompt.git_branch] format`, only inside a git work tree |
| `{character}` | The prompt symbol (see `[prompt.character]`) |
| `{language_context}` / `{context_icon}` | The `[prompt.contexts]` format of the detected project type; the shell name when none matches |

A token may be styled as `[{token}](style)`. Plain text in `format` is not
styled (`[text](style)` is literal there); use module formats for that.

**Styles** (used in `[text](style)` and `[{token}](style)`): space-separated
words `bold`, `italic`, `underline`, `dim`, a color name (`black`, `red`,
`green`, `yellow`, `blue`, `magenta`, `cyan`, `white`, `orange`, `pink`,
`purple`, `gray`/`grey`, `lime`, `teal`) or a 256-color number (`242`).
Unknown words are ignored.

**Module formats** use the `[text](style)` syntax plus the module's
variables. Config text is always literal: `$(...)` in it never runs.

#### `[prompt.username]`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `format` | string | `"[$user](white bold) in "` | `$user` = the user name. |
| `show_always` | boolean | `false` | Show the user name everywhere. Default: only over SSH or as root. |

#### `[prompt.hostname]`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `format` | string | `"$hostname"` | `$hostname` = short host name. |

#### `[prompt.localip]`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `format` | string | `"$localip"` | `$localip` = IPv4 address (`ipconfig getifaddr en0`, else `ip -4 route get 1`), computed at every prompt. |

#### `[prompt.dir]`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `format` | string | `"[$dir](cyan bold) "` | `$dir` = current dir with `~`, `$pwd` = full path, `$basename` = last component. |

#### `[prompt.git_branch]`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `format` | string | `"on [$branch](magenta bold) "` | `$branch` = branch name, or the first 7 characters of the commit when detached. Read from `.git/HEAD` without running git (worktrees, submodules and `$GIT_DIR` included). |

#### `[prompt.character]`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `success_symbol` | string | `➜` | Symbol after a successful command (and in vi insert mode). |
| `error_symbol` | string | `✗` | Symbol after a failed command. |
| `vimcmd_symbol` | string | `❮` | vi normal mode. |
| `vimcmd_visual_symbol` | string | `❮` | vi visual mode. |
| `vimcmd_replace_symbol` | string | `❮` | vi replace mode: `R`, and `r` while it waits for the character. |

Only the text between `[` and `]` is used (`"[>](green)"` gives `>`); the
style part is ignored. Colors are fixed: green on success, red on error;
in vi mode orange (202) insert, green normal, purple (129) visual/replace.

#### `[prompt.contexts]`

```toml
[prompt.contexts]
rust   = { format = "rs $version ", detect = ["Cargo.toml"] }
kotlin = { format = "kt ", detect = ["*.kt", "build.gradle.kts"] }
```

One line per project type: `name = { format = "...", detect = [...] }`.

| Field | Meaning |
|---|---|
| `format` | What `{language_context}` shows. `$version` = the tool version, fetched in the background (needs `async_rprompt`); only the built-in names `rust`, `bun`, `dart`, `ruby`, `elixir`, `odin`, `golang`, `deno`, `nodejs`, `python`, `zig` have a version command. |
| `detect` | File names or globs (`*`, `?`) checked in the current directory on `cd`. The first entry (in file order) with a match wins. Entries with characters other than letters, digits, `. _ - / + @ * ?` or non-ASCII are ignored. |

User entries are tested before the built-in detectors (rust, bun, gleam,
swift, dart, php, ruby, elixir, erlang, haskell, julia, odin, golang, nim,
ocaml, nix, deno, elm, crystal, perl, buf, nodejs, java, scala, python, zig,
rlang, lua, docker, aws). A user entry replaces the built-in one of the same
name. A built-in match without a user `format` shows the shell name.

#### `[prompt.interactive]`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `toggle_enabled` | boolean | `false` | Bind `toggle_key` to switch between the full and the minimal prompt. Bound in `viins` + `vicmd` with `vi_mode`, else in `emacs`. |
| `toggle_key` | string | `"^P"` | Key sequence for the toggle. |
| `transient_enabled` | boolean | `true` | Minimal prompt = current dir + success/error symbol. `false`: minimal prompt = `%~ ➜ `. Only reachable through the toggle. |
| `vi_mode_indicator` | boolean | `true` | With `vi_mode`, track the keymap in `{character}`. `zle-line-init` / `zle-keymap-select` already defined are kept and run first. |
| `context_aware` | boolean | `true` | Detect the project type on `cd` (for `{language_context}`). |
| `async_rprompt` | boolean | `true` | Background job after each command: git changed-file count (right prompt) and context version. Started only in a git work tree or a context with a version command; elsewhere the right prompt is cleared without forking. |
| `rprompt_format` | string | `"[ {git_pending}](242)"` | Right prompt, shown when the work tree has changes. `{git_pending}` = number of changed files, `{git_branch}` = branch. |

#### Prompt in fish

core.fish defines `fish_prompt` (and `fish_right_prompt` with
`async_rprompt`) from the same tables, in interactive shells, before the
plugins: a plugin or `config.fish` code that defines `fish_prompt` later
wins. Same tokens, module variables, styles (as ANSI colors; a styled part
ends with a full reset), symbols and colors. A render runs only fish
builtins, except `{localip}`. Differences:

- `vi_mode = true` sets `fish_key_bindings` to `fish_vi_key_bindings`;
  `{character}` follows `$fish_bind_mode` (insert, default = normal, visual,
  replace / replace_one) and `fish_mode_prompt` is emptied. Without
  `vi_mode` the key bindings and `fish_mode_prompt` are left alone.
- `toggle_key` must be `^X` (a letter, bound as `\cx`); it is bound from
  `fish_user_key_bindings`, which calls one defined before wayu first. Other
  keys are not bound (a comment in core.fish says so).
- `[prompt.contexts]` detection runs on `$PWD` changes; a glob matches with
  `*` only.
- `async_rprompt` starts `fish --no-config` in the background per prompt
  (only in a git work tree or a versioned context) and repaints on
  `SIGUSR1`.

### `[scripts]`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `default_lang` | string | `"swift"` | Language of `wayu script new` without `--lang`: `swift`, `python`, `ruby`, `node`, `bun`, `bash`, `zsh`, `fish`, `perl`, `lua` or `sh`. Another value is an error for `toml validate` (exit `65`), `doctor` and `script new` (exit `78`). |

```toml
[scripts]
default_lang = "python"
```

### `[secrets]`

```toml
[secrets]
backend = "auto"
```

Encrypted constants (`wayu const add NAME [VALUE] --secret`) are kept in
`<data>/secrets.json` (`0600`, managed by wayu, not for hand edits):

```json
{"version": 1, "cipher": "chacha20poly1305", "values": {"NAME": "<base64 nonce||ciphertext||tag>"}, "run_only": ["NAME"]}
```

Each value is encrypted with ChaCha20-Poly1305 under a 256-bit master key,
with a random nonce and the variable name as associated data. In `entries.json` a
secret is `{"name": "NAME", "secret": true}`, with no value, at its place
in the constants' order. A run-only secret (`--run-only`) is also listed in
`run_only` (written only when non-empty) and marked `"run_only": true` in
`entries.json`; it is never written to the session cache, so shells never
export it, and only `wayu secrets run` decrypts it. The mark is part of the
associated data (`NAME` + `\0run-only`), so removing it from `secrets.json`
makes the value fail to decrypt rather than get exported. The file is read
strictly: any other field, text after the object, a name that is not a shell
variable name, a non-string value, or a `run_only` name missing from
`values` makes it malformed (secret commands exit `78`, `doctor` reports an
error). `backend` says where the master key lives:

| `backend` | Key storage |
|---|---|
| `"auto"` (default) | `keychain` on macOS; `secret-service` on Linux when `secret-tool` is on PATH; else `file` |
| `"keychain"` | macOS login keychain: generic password, service `wayu-master-key`, account `wayu-<id>`, via `security`. Storing (first secret, `rekey`) passes the key on `security`'s command line for a moment, where other processes of the same user could see it. |
| `"secret-service"` | freedesktop Secret Service via `secret-tool` (`service wayu account wayu-<id>`); the key goes over stdin |
| `"file"` | `<config>/secret.key`: 64 hex characters, `0600`, created exclusively; refused when group/other can read it. Protects against reading the data dir alone, not against reading your whole home. |

`<id>` is 16 hex digits identifying the data dir (FNV-1a 64 of its path, the
same id as in the session cache name): each data dir (another
`WAYU_DATA_DIR`, a test `HOME`) has its own key and never reads another's.
`wayu doctor` prints the account (`keychain (account wayu-…)`). A key left by wayu 6.0 (one shared item: keychain account `wayu`, Secret Service `account master`) is copied to the per-data-dir account the first time it is needed, when it decrypts the data dir's `secrets.json`; the old item is kept.

Any other value is an error (`toml validate` exits `65`; secret commands exit
`78`). The key is created with the first secret; wayu never creates a new
key while `secrets.json` holds values (it would make them undecryptable).
`wayu secrets rekey` replaces it and re-encrypts everything: the new store
is written to `secrets.json.rekey` first, then the key is saved, then the
file is renamed over `secrets.json`; if wayu is interrupted in between, the
next command that reads the store finishes or undoes the rekey, whichever
matches the stored key.

At shell start `core.<ext>` sources the session cache
`${XDG_RUNTIME_DIR:-${TMPDIR:-<data>/run}}/wayu-<uid>/secrets-<id>.<ext>`
(single-quoted `export` / `set -gx` lines, `0600` in a `0700` dir you own)
when it is newer than `secrets.json`, without forking. The dir must be yours
and not a symlink (else `<data>/run/wayu-<uid>` is used), and the file must
be yours and not a symlink; with neither `XDG_RUNTIME_DIR` nor `TMPDIR` set
the cache lives under `<data>/run` (`0700`), never in a shared `/tmp`. Otherwise it runs
`wayu secrets cache` once to (re)write it. If the key is unavailable or a
value does not decrypt, one `wayu: secrets not loaded: …` line goes to stderr
and startup continues without the secrets. Every change to `secrets.json`
deletes the cache; `wayu secrets lock` deletes it by hand. Secret values are
literal: no `$VAR` or `~` expansion.

Decrypted values are never written to `core.<ext>`, `path_sync.<ext>`,
`turbo.<ext>`, backups or logs; only to the session cache and to the output
of `wayu const get NAME` (and to the environment of `wayu secrets run`'s
command). `wayu doctor` checks the backend, the key, the
store's mode, that every secret decrypts, and the cache dir.

### Keys wayu does not read

wayu reads only the keys and tables listed above. Anything else (for example
`wayu_version`, `[settings] auto_backup`, `[path]`, `[[plugins]]` — plugins
live in `plugins.json` —, `[profile.*]`, `[constants]`) has no effect:
`wayu toml validate` prints a warning per unknown key or table, with its line
(`⚠ line 5: unknown key settings.auto_backup (ignored)`), and still exits `0`;
`wayu doctor` reports them as a warning. Keys inside an unknown table are not
listed one by one.

## Managed data

PATH entries, aliases and constants are data wayu manages: `wayu path|alias|
const add|rm`, the TUI and templates edit them, and `wayu build` compiles them
into `core.<ext>`. They are not read from `wayu.toml`; a `[paths]`,
`[aliases]` or `[env]` table there is an error for `wayu toml validate` and
`wayu doctor`, naming the command to use instead.

### entries.json

`$WAYU_DATA_DIR/entries.json`:

```json
{
  "version": 1,
  "paths": [
    {"key": "local_bin", "dir": "~/.local/bin"},
    {"key": "cargo_bin", "dir": "$HOME/.cargo/bin"},
    {"key": "go_bin", "dir": "$GOPATH/bin"},
    {"key": "homebrew_bin", "dir": "/opt/homebrew/bin"}
  ],
  "aliases": [
    {"name": "ll", "value": "ls -lah"},
    {"name": "gs", "value": "git status"},
    {"name": "onlead-logs", "value": "tail -f /var/log/onlead.log"},
    {"name": "gl", "value": "git log --format=\"%h %s\""}
  ],
  "env": [
    {"name": "EDITOR", "value": "nvim"},
    {"name": "GOPATH", "value": "$HOME/go"},
    {"name": "GOBIN", "value": "${GOPATH}/bin"},
    {"name": "PAGER_OPTS", "value": "${LESS:--R}"},
    {"name": "PRICE", "value": "costs $5"},
    {"name": "GITHUB_TOKEN", "value": "ghp_example"}
  ]
}
```

| Field | Meaning |
|---|---|
| `version` | The number `1` (required). Any other value, `"1"` or `1.0` is an error. |
| `paths[]` | `{"key", "dir"}`: PATH entries, highest priority first. `key`: letters, digits, `_`; `dir`: non-empty, no `:` or newline. |
| `aliases[]` | `{"name", "value"}`: aliases. `name` follows the [alias name rule](#aliases); `value` must not be blank. |
| `env[]` | `{"name", "value"}`: constants (exported variables), in export order. `name`: letters, digits, `_`, not starting with a digit. An encrypted one is `{"name", "secret": true}` (no `value`), optionally `"run_only": true`. |
| `fpath[]` | Strings, zsh only: completion dirs put on `fpath` (first = front) before wayu's `compinit`; the dump is rebuilt when their file list changes. Same expansion as PATH entries. Written only when non-empty (`wayu completions fpath`, `wayu optimize`). |
| `generators[]` | `{"shell", "cmd", "args"}`: `source <(cmd args)` / `eval "$(cmd args)"` lines moved by `wayu optimize`. `core.<shell>` (only that shell's) runs `_wayu_evalcache cmd args` after everything else, before the aliases; zsh/bash in interactive shells only. `args` follows the `[tools]` args rules. Written only when non-empty. |

- **Writes** are atomic (temp file + rename, symlinks kept), under the lock
  shared by concurrent wayu commands, owner-only (`0600`), pretty-printed with
  one entry per line, in stable order: a write changes only the entries it
  touches. Each write is backed up first (`wayu backup restore entries`).
- **Reading is strict.** A missing file is an empty store. Anything else
  must be exactly one JSON document (nothing after it, no trailing commas, no
  key twice in an object, valid UTF-8, no NUL character) that fits the table
  above: every field with its type, no unknown field, required fields present,
  names valid, the same key / name at most once per section. Otherwise every
  command that reads it exits `78`, naming the file and the problem; nothing
  is written. `wayu doctor` reports it too.
- It is safe to edit by hand while no wayu command runs; run `wayu build`
  afterwards (open shells also notice a newer file, see
  [PATH entries](#path-entries)).

### PATH entries

`wayu path add ~/.local/bin`, `wayu path add go_bin='$GOPATH/bin'`: each
entry is a `key` (a label) and a `dir`.

- **Order is priority.** Entries go to the front of `PATH` in store order (the
  first entry wins). `wayu path add` appends; existing entries never move.
- **Keys are labels.** The shell never sees them; `wayu path rm <key>` and
  `wayu path add name=dir` use them. `path add` derives one when not given:
  lowercase, non-alphanumerics to `_`, `.local` to `hidden_local`, a generic
  basename (`bin`, ...) prefixed with its parent (`/usr/local/bin` to
  `local_bin`), `_2`, `_3` on collision.
- **Expansion happens in the shell**, at startup and at each re-sync: a
  leading `~` or `~/` becomes `$HOME`; `$NAME` and `${NAME}` expand (an
  constant is already exported because constants come first). Nothing
  else expands: `${X:-y}`, `$(...)`, a bare `$` stay literal. An entry whose
  variable is unset or empty is dropped (never turned into `/bin`).
- **Skipped at runtime:** directories that do not exist (re-checked when the
  list is re-applied), values containing `:` or a newline (warning on stderr),
  empty values, and repeats of an earlier value.
- **Relative paths** (`./node_modules/.bin`) are kept as written: the shell
  tests them against its current directory when the list is applied and, once
  on `PATH`, resolves them against the current directory at every command
  lookup. `wayu doctor` counts them with the entries it leaves alone, never
  as missing.
  `wayu path add` itself never stores a relative path: it resolves `~`,
  `$VAR` and relative arguments to an absolute directory, which must exist (and be a directory).
- **Integration with PATH:** wayu removes only directories it put on `PATH`
  itself (tracked in `_WAYU_PATHS_MANAGED`); a system directory that is also
  a PATH entry is moved to wayu's position but never removed. In zsh the
  session also gets `typeset -U path`. In fish the dirs move to the front in
  store order, like `fish_add_path -gpm`.

- **Open shells** pick up PATH changes at their next prompt: the prompt hook
  re-applies `path_sync.<ext>` when its signature changes, and runs `wayu
  build` first when `wayu.toml` or `entries.json` is newer than it. That
  build never compiles: stale scripts are built by a background `wayu
  script build`. When that build fails (e.g. a malformed `entries.json`
  save), the hook writes `path_sync.<ext>.regen-failed` and tries again
  after the next save of either file.

### Aliases

`wayu alias add ll 'ls -lah'`: each entry is a `name` and a command
(`value`).

One rule for `alias add`, the TUI, templates and `entries.json`:

| Rule | |
|---|---|
| Name characters | Printable ASCII except whitespace, quotes, `` ` `` `$ \ = / ^ ; & \| < > ( ) { } [ ] * ? # ~ !`; not starting with `-`. `..`, `g.st`, `1x`, `k8s-ctx` are fine |
| Reserved names | `.` and `if then else elif fi case esac for while until do done in function time select coproc declare typeset local export readonly unset return exit cd pwd echo test true false` are refused |
| Length | At most 255 characters |
| Command | Must not be blank; no NUL byte, valid UTF-8 |

Generated code: zsh/bash `alias name='command'`; fish a function
`function name --wraps 'command' --description 'alias name command'` whose body
is `eval 'command' (string escape -- $argv)` (what fish's `alias` defines, but
the command is never parsed as code when the function is defined; arguments
pass through literally).
The command is single-quoted and stored verbatim, so `$VAR` in it expands when
the alias runs. Aliases are emitted sorted by name, last in `core.<ext>`
(after plugins and tools), so an alias never breaks a function wayu or a
plugin defines.

### Constants

`wayu const add GOPATH '$HOME/go'`: each entry is a `name` and a `value`,
exported as `export NAME="..."` (zsh/bash) or `set -gx NAME "..."` (fish), in
store order, so a later value can use an earlier one.

Names: an ASCII letter or `_`, then letters, digits or `_` (no `-`), not a
reserved word (list above), at most 255 characters. `const add` refuses
other names; the generator skips them with a comment. Lowercase names are
allowed (`const add` warns that the convention is `UPPER_CASE`). An empty
value is exported as empty.

**Expansion.** A leading `~` or `~/` becomes `$HOME`. Only references to
named variables expand; every other character, `$` included, is literal:

| Written | zsh / bash | fish |
|---|---|---|
| `$NAME` | expands (emitted as `${NAME}`, so `$HOME:h` or `$HOME[1]` are not zsh modifiers / subscripts) | expands |
| `${NAME}` | expands | expands |
| `${NAME<op>...}`, op = `-` `+` `?` (each also with a leading `:`), `#`, `%`, `/` | expands, e.g. `${X:-d}`, `${X#pre}`, `${X/a/b}` | literal |
| `${#NAME}` | expands | literal |
| Any other `${...}`: `${X=v}` / `${X:=v}` (would assign X), `${X@P}`, `${X[1]}`, `${X:1}`, `${X: -2}`, `${X^}`, `${HOME:h}`, `${(e)X}` | literal | literal |
| `$1`, `$$`, `$?`, `$%`, a trailing `$`, an unclosed `${` | literal | literal |
| `$(cmd)`, `` `cmd` `` | literal (never run) | literal |
| `"`, `\` | literal | literal |

The text inside an expanding `${NAME:-...}` follows the same rules, so
`${X:-$(cmd)}` never runs `cmd`.

**Secret masking.** An entry looks secret when its name contains (any case)
`KEY`, `TOKEN`, `SECRET`, `PASSWORD`, `PASSWD`, `PASS`, `API`, `CREDENTIAL`,
`AUTH`, `PRIVATE`, `SESSION`, `COOKIE`, `SIGNATURE`, `CERT` or `DSN`, or when
its value starts with a known token prefix (`sk-`, `sk_`, `pk_live_`,
`rk_live_`, `ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`, `github_pat_`, `glpat-`,
`xoxb-`, `xoxp-`, `xoxa-`, `xapp-`, `AKIA`, `ASIA`, `AIza`, `ya29.`, `eyJ`,
`npm_`, `hf_`, `-----BEGIN`) or is a URL with a password
(`scheme://user:pass@host`). Empty values are never masked.

| Where | Shows |
|---|---|
| `wayu const list` (text and `--json`, with or without `--full`) | `********` for secret-looking constants and environment variables; `--reveal` shows them |
| TUI constants view | Masked; `v` toggles reveal |
| Dry-run previews | Masked |
| `wayu const get NAME` | The real value |

Masking only affects display: `core.<ext>` holds and exports the real
values. Files holding constant values (`entries.json`, its backups,
`core.<ext>`, `path_sync.<ext>`) are owner-only (`0600`).

## Other files you edit

### hooks.conf

`$WAYU_CONFIG_DIR/hooks.conf` runs a command before or after a wayu
operation. `wayu hooks` shows the configured hooks; `wayu hooks edit` opens
the file (creating a commented example).

```
# test hooks
post_constant_add = echo added {name}={value} >> ~/hook.log
pre_constant_remove = sh -c 'echo removing {name} >> ~/hook.log'
post_constant_remove = echo "gone: $WAYU_HOOK_NAME" >> ~/hook.log
```

Format: one `event = command` per line; `#` starts a comment line; a pair
of quotes is removed only when it wraps the whole command as one quoted
string (`pre_export = "echo 'Generating...'"`), so `"/bin/echo" {path} "done"`
is kept as written; unknown keys
are ignored; for a repeated key the last line wins.

| Event | `{path}` | `{name}` | `{value}` |
|---|---|---|---|
| `pre_path_add`, `post_path_add` | directory | | |
| `pre_path_remove`, `post_path_remove` | directory (also when removed by key) | | |
| `pre_alias_add`, `post_alias_add`, `pre_alias_remove`, `post_alias_remove` | | alias name | command |
| `pre_constant_add`, `post_constant_add`, `pre_constant_remove`, `post_constant_remove` | | variable name | value (empty for an encrypted secret) |
| `pre_plugin_install`, `post_plugin_install` | | plugin name | |
| `pre_export`, `post_export` (around `wayu export` / `build turbo`) | | | |

The same values are in the environment as `WAYU_HOOK_PATH`, `WAYU_HOOK_NAME`
and `WAYU_HOOK_VALUE` (empty when not meaningful).

Placeholder quoting:

| Written | Result |
|---|---|
| Unquoted: `echo Adding {path}` | Replaced by `"${WAYU_HOOK_PATH}"`: the value is one word, never parsed as code. |
| Inside `'...'`: `sh -c 'echo {path}'` | Left as `"${WAYU_HOOK_PATH}"` for the inner shell, which expands it quoted. |
| Inside `"..."`: `sh -c "echo {value}"` | Refused. Any wayu operation that would run hooks exits `78` before writing anything and names the line; `wayu hooks` marks it `INVALID`. Use `"$WAYU_HOOK_VALUE"` when you need double quotes. |

Hooks run with `sh -c`, stdin on `/dev/null`; their exit status is ignored.
In the CLI a hook's stdout and stderr are shown (in the TUI they are
captured). Pre-hooks run only when the operation will change something,
post-hooks only after a successful write, and none under `--dry-run`. Hooks
run outside wayu's config lock (pre-hooks before it is taken, post-hooks
after it is released), so a hook may run `wayu` itself. A hook still running
after 30 s is killed with its child processes (the CLI prints a warning
naming it); a `timeout = <seconds>` line in hooks.conf changes that limit
(whole seconds above 0; other values keep 30).

### plugins.json

`$WAYU_DATA_DIR/plugins.json` (JSON5: comments and trailing commas allowed)
is written by `wayu plugin ...` and may be hand-edited or synced. Plugins are
cloned to `$WAYU_DATA_DIR/plugins/<name>`.

```json5
{
  "version": "1.0",
  "last_updated": "2026-11-07T14:35:37Z",
  "plugins": [
    {
      "name": "zsh-autosuggestions",
      "url": "https://github.com/zsh-users/zsh-autosuggestions.git",
      "enabled": true,
      "shell": "ZSH",
      "installed_path": "/home/me/.local/share/wayu/plugins/zsh-autosuggestions",
      "use": [],
      "template": "Source",
      "dependencies": [],
      "priority": 100,
    },
  ],
}
```

| Field | Type | Meaning |
|---|---|---|
| `version` | string | `"1.0"`. |
| `last_updated` | string | Set by wayu on every write. |
| `plugins[].name` | string | Required, unique: one path component, not starting with `-`. |
| `plugins[].display_name` | string | Alternative name accepted by `plugin get/enable/...`. |
| `plugins[].url` | string | Clone URL (validated). |
| `plugins[].source_type` | enum | `GitHub`, `GitLab`, `Gist`, `Git`, `Remote`, `Local`. |
| `plugins[].enabled` | boolean | Only enabled plugins load. |
| `plugins[].shell` | enum | `ZSH`, `BASH`, `BOTH` (zsh + bash), `FISH`, `ANY` (all three). |
| `plugins[].installed_path` | string | Clone dir; no leading `-`, no control characters. |
| `plugins[].use` | array of strings | Files to source, matched at the repository root: exact names or one-`*` globs (`"*.plugin.zsh"`); no `/` (a `../` path is refused). Set with `wayu plugin add <url> --use <file-or-glob>` (repeatable). Empty: auto-detect (below). |
| `plugins[].template` | enum | How each file is loaded: `Source` (`source file`), `Path` (prepend the plugin dir to `PATH`), `FPath` (prepend to `FPATH`), `Autoload` (`autoload -Uz name`), `Eval` (`eval "$(file)"`). |
| `plugins[].git` | object | `ref_type` (`Branch`, `Tag`, `Commit`), `branch`, `tag`, `commit`, `pinned_ref`, `last_checked`, `remote_commit`. Refs are validated. |
| `plugins[].dependencies` | array of strings | Plugin names loaded before this one. Must be valid plugin names; a cycle is an error. A missing or disabled dependency is noted as a comment in `plugins.<ext>`. |
| `plugins[].priority` | integer | Load order among plugins whose dependencies are met; lower loads earlier (default 100). Ties keep file order. |
| `plugins[].conflicts` | object | Written by wayu's conflict detection. |

Enum values are strings, matched case-insensitively; numbers are rejected.
Unknown keys are ignored (and dropped on the next write). Any invalid value makes every command that reads
`plugins.json` exit `78` with the plugin and field named.

Auto-detected entry file (no `use`): the first that exists of
`<name>.plugin.<ext>`, `<name>.<ext>`, `<name>-init.<ext>`, `init.<ext>`,
`plugin.<ext>`, then `<name>.zsh-theme` (zsh) and `<name>.plugin.sh`,
`<name>.sh` (zsh, bash); otherwise every top-level `*.<ext>` (zsh: then
`*.zsh-theme`). fish also loads `conf.d/*.fish` and `functions/*.fish`.

### extra.\<ext\> and tools.\<ext\>

`$WAYU_CONFIG_DIR/tools.<ext>` and `$WAYU_CONFIG_DIR/extra.<ext>` are plain
shell scripts for anything `wayu.toml` does not cover (`wayu init` creates
commented templates). They are sourced on every shell start, tools first:

- zsh/bash: from `core.<ext>`, after the deferred `[tools]` and before
  login-only tools and aliases.
- fish: from `init.fish`, after `core.fish`.

`wayu config extend` edits `extra.<ext>`; `wayu config scan --fix` moves
inline scripts from `.zshrc` into it. Edits take effect in new shells
without `wayu build`.

### config.\<ext\>

If `$WAYU_CONFIG_DIR/config.<ext>` exists, its content is copied into
`core.<ext>` (after functions, before the helpers) when core is generated.
Unlike `extra.<ext>` it is not sourced at startup: run `wayu build` after
editing it.

### functions/

`$WAYU_DATA_DIR/functions/` holds one file per function
(`wayu function add <name>` writes `functions/<name>.<ext>`). Sourced at
startup:

| Shell | Sources |
|---|---|
| zsh | `*.zsh` only |
| bash | `*.bash` only |
| fish | `*.fish` only |

### scripts/ and bin/

`$WAYU_DATA_DIR/scripts/` holds the sources of `wayu script` (one
`NAME.<ext>` per script; the directory is the list) and
`$WAYU_DATA_DIR/bin/` what runs: a relative symlink to the source for
interpreted languages, the compiled binary plus `.NAME.hash` (hash of the
source and build command it was built from) for swift and any source with a
`wayu: build = ...` header (see `wayu script` in docs/cli.md). Use `wayu script` rather than editing
`bin/`. Once `bin/` holds a script, `core.<ext>` and `path_sync.<ext>` put it
first among wayu's PATH entries (zsh, bash, fish), so a script may shadow a
tool of the same name.

### completions/

`$WAYU_DATA_DIR/completions/` (`wayu completions add` / `generate` write
here):

| Shell | Used as |
|---|---|
| zsh | Prepended to `fpath` (files named `_<command>`); `compinit` runs in interactive shells and rebuilds `.zcompdump` when the dir's file list, or any `fpath` dir or its mtime, changed |
| bash | Sources `*.bash-completion` and `*.bash` |
| fish | Prepended to `fish_complete_path` |

### alias-sources.conf

`$WAYU_CONFIG_DIR/alias-sources.conf` lists external alias sources that
`wayu alias list` shows as read-only (they are not defined in the shell):

```
# dir <path> <command_template>
dir ~/.config/fabric/patterns fabric --pattern {name}
```

Each entry of `<path>` (leading `~` expanded) becomes a name; `{name}` in the
template is replaced with it. Lines not starting with `dir ` and comment lines
are ignored.

## Generated files

Do not edit these; wayu overwrites them. They are regenerated by `wayu build`,
`wayu init` and every `path` / `alias` / `const` change (CLI or TUI), for
every shell initialized in the data dir.

| File (data dir) | Content |
|---|---|
| `init.<ext>` | Entry point your rc file sources: loads `core.<ext>` (prints a hint to run `wayu build` when it is missing). Written by `wayu init`. An unmodified copy of the current or previous template is replaced when the template changes (backup first); an edited one is kept, with a warning. |
| `core.<ext>` | Everything `init.<ext>` loads, precomputed from `wayu.toml` and `entries.json` (zsh also `core.zsh.zwc`, compiled in the background). |
| `path_sync.<ext>` | The PATH entry list (after `bin/` when it holds a script); line 1 is its signature. The prompt hook re-sources it when the signature changes. |
| `turbo.<ext>` | zsh/bash. Same content as `core.<ext>`, refreshed with it, only if it exists (created by `wayu export`). |
| `plugins.<ext>` | Plugin loader, regenerated on any `plugin` change and by `wayu init`. |
| `plugins/config.zsh` | `[settings] autosuggestions_accept_keys` bindings. |
| `secrets.json` | Encrypted constants (see [`[secrets]`](#secrets)); written by `wayu const add --secret`, `const rm`, `secrets rekey`. Not generated from wayu.toml. |
| `backup/` | Timestamped backups `<file>.backup.YYYY-MM-DD_HH-MM-SS.UUUUUU[-N]` (UTC), 5 newest per file (see `wayu backup`). `<file>` is the name of a file directly in the config/data dir, `@` + its relative path with `/` as `%` for a nested one (`@functions%init.zsh`), or the path of a file outside them (`.zshrc`, `.config%zsh%.zshrc`). Files named otherwise are ignored. |

Also `$WAYU_DATA_DIR/.wayu.lock` (lock shared by concurrent wayu commands)
and the evalcache under `${XDG_CACHE_HOME:-~/.cache}/wayu/evalcache`.

## Load order

`core.zsh` / `core.bash`, each `# === ... ===` line a section:

1. `WAYU_CONFIG_DIR` / `WAYU_DATA_DIR` exports (only when not default)
2. Constants
3. Secrets (session cache; only when `secrets.json` holds values)
4. `bin/` (scripts) and PATH entries (and the live PATH sync hook)
5. Completions (zsh: `fpath`; `compinit` and the compinit guard in
   interactive shells, see [`[settings]`](#settings))
6. `functions/`
7. `config.<ext>` content
8. Helpers (evalcache; zsh: zsh-defer in interactive shells, `wayu_compile`)
9. Eager `[tools]`
10. Native prompt (zsh, interactive, `[prompt] enabled = true`)
11. Plugins (`plugins.<ext>`; zsh: `plugins/config.zsh`, interactive
    shells only, after the first prompt with `defer_plugins`; zsh with
    `[settings] autosuggest` / `highlight`: the built-in suggestions and
    syntax highlighting first)
12. Deferred `[tools]`
13. `tools.<ext>`
14. `extra.<ext>`
15. Login-only `[tools]`
16. Aliases

`core.fish`: directory exports, constants, secrets, PATH entries, completions,
`functions/*.fish`, `config.fish` content, evalcache helper, eager `[tools]`,
the native prompt (`[prompt] enabled = true`), `plugins.fish`, deferred
`[tools]`, login-only `[tools]`, aliases. `init.fish` then sources
`tools.fish` and `extra.fish`; `turbo.fish` (`wayu export`) is core.fish
followed by those two.
