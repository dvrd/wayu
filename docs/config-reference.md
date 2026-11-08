# wayu configuration reference

Everything wayu reads: `wayu.toml` (every table and key), the other files you
may edit (`hooks.conf`, `plugins.json`, `extra.<ext>`, `tools.<ext>`,
`functions/`, `alias-sources.conf`, `completions/`), where they live, and which
files are generated.

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
  - [`[paths]`](#paths)
  - [`[aliases]`](#aliases)
  - [`[env]`](#env)
  - [`[settings]`](#settings)
  - [`[tools]`](#tools)
  - [`[prompt]`](#prompt)
  - [Keys wayu does not read](#keys-wayu-does-not-read)
- [Other files you edit](#other-files-you-edit)
  - [hooks.conf](#hooksconf)
  - [plugins.json](#pluginsjson)
  - [extra.\<ext\> and tools.\<ext\>](#extraext-and-toolsext)
  - [config.\<ext\>](#configext)
  - [functions/](#functions)
  - [completions/](#completions)
  - [alias-sources.conf](#alias-sourcesconf)
- [Generated files](#generated-files)
- [Load order](#load-order)

## Directories

| Variable | Default | Holds |
|---|---|---|
| `WAYU_CONFIG_DIR` | `~/.config/wayu` | Files you edit: `wayu.toml`, `hooks.conf`, `alias-sources.conf`, `extra.<ext>`, `tools.<ext>`, `config.<ext>`, `functions/` |
| `WAYU_DATA_DIR` | the config dir | Generated and runtime files: `init.<ext>`, `core.<ext>`, `path_sync.<ext>`, `turbo.<ext>`, `plugins.json`, `plugins.<ext>`, `plugins/`, `completions/`, `backup/` |

- Each variable is read independently: `WAYU_DATA_DIR` applies whether or not
  `WAYU_CONFIG_DIR` is set.
- `init.<ext>` finds its files next to itself, so the rc line
  (`source <data>/init.zsh`) works without exporting either variable to the
  shell. If `WAYU_CONFIG_DIR` is unset, the config dir is the init file's dir
  when that dir holds `wayu.toml`, else `~/.config/wayu`.
- When either dir differs from the default, `core.<ext>` exports
  `WAYU_CONFIG_DIR` / `WAYU_DATA_DIR`, so `wayu` commands typed in that shell
  use the same dirs.
- The `[tools]` evalcache lives outside both:
  `${XDG_CACHE_HOME:-~/.cache}/wayu/evalcache` (`wayu build clean` deletes it).

## wayu.toml

`$WAYU_CONFIG_DIR/wayu.toml` is the single source of truth for PATH, aliases,
environment variables, `[tools]` loaders and the native prompt. `wayu init`
creates this scaffold:

```toml
[shell]
type = "zsh"

[aliases]

[env]
```

After editing it by hand, run `wayu build`. Open shells also pick up
`[paths]` changes at their next prompt (the prompt hook runs `wayu build`
when `wayu.toml` is newer than `path_sync.<ext>`); everything else applies to
new shells. `wayu toml validate` checks the file (see
[Strict and lenient reading](#strict-and-lenient-reading)).

### Complete example

This file passes `wayu toml validate` and `wayu build` as-is.

```toml
[shell]
type = "zsh"

# PATH: first entry = highest priority. Keys are labels only.
[paths]
local_bin    = "~/.local/bin"
cargo_bin    = "$HOME/.cargo/bin"
go_bin       = "$GOPATH/bin"            # dropped while GOPATH is unset
homebrew_bin = "/opt/homebrew/bin"

[aliases]
ll         = "ls -lah"
gs         = "git status"
onlead-logs = "tail -f /var/log/onlead.log"
gl         = 'git log --format="%h %s"'   # literal string: no escapes

[env]
EDITOR     = "nvim"
GOPATH     = "$HOME/go"
GOBIN      = "${GOPATH}/bin"
PAGER_OPTS = "${LESS:--R}"
PRICE      = "costs $5"                 # `$5` is not a name: stays literal
HISTSIZE   = 50000                      # integers are read as text
GITHUB_TOKEN = "ghp_example"            # masked in list views

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

What it generates in `core.zsh` (excerpt):

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

| Value | Example | In `[paths]` / `[aliases]` / `[env]` |
|---|---|---|
| Basic string | `"a \"b\" \t \u00e9"` | Escapes decoded |
| Literal string | `'C:\no\escapes'` | Taken verbatim |
| Multi-line string | `"""..."""`, `'''...'''` | Used as written (newline after the opening quotes dropped) |
| Integer | `1_000`, `0x1F` | Decimal text: `1000`, `31` |
| Float, date-time | `1.5`, `1979-05-27` | Text as written |
| Boolean | `true` | `"true"` / `"false"` |
| Array, inline table | `["a"]`, `{ a = 1 }` | Entry skipped |

Arrays and inline tables are valid only where a key below says so:
`[settings] autosuggestions_accept_keys`, `[tools]` entries and their
`hook_commands`, and `[prompt.contexts]` entries.

Keys:

- A bare key may use `A-Z a-z 0-9 _ -`. Anything else needs quotes:
  `"my key" = ...`. Quoted keys are decoded everywhere (`"q\"k"` is the name
  `q"k`).
- A dotted bare key inside `[paths]`, `[aliases]` or `[env]` (`g.st = ...`) is
  read as the single name `g.st`.
- When wayu writes an entry it uses a bare key when TOML allows and a quoted
  basic string otherwise (`"g.st" = "git status"`), and escapes control
  characters in values (`\u001B`). Everything wayu writes is valid TOML.
- wayu edits `wayu.toml` line by line: only the entry being changed is
  rewritten; comments, blank lines, order and keys it does not know are kept
  byte-for-byte.

### Strict and lenient reading

| Reader | On a syntax error |
|---|---|
| `wayu toml validate`, `wayu doctor`, `wayu backup restore` (strict) | Fail and name the line: `Failed to parse <file>: line 5: invalid value "ls" (strings must be quoted)` |
| Everything else: `alias/const/path list`, the generator (`wayu build`, every write), the TUI, the in-place editor (lenient) | Use what was recovered. A `key = value` line whose value is not valid TOML is read the old one-line way: `ll = ls -la` is the alias `ls -la` |

Strict-only failures: a key defined twice in one table, a table defined twice,
an integer with leading zeros (`007`), an unquoted string. Lenient readers
resolve a duplicate `[aliases]` / `[env]` key as last value, first position.
The table editor refuses to write when the table it edits holds a broken
multi-line value (`wayu.toml line N: unterminated array (missing ']') in
[env] ...`).

After parsing, `wayu toml validate` also checks:

| Check | Error |
|---|---|
| Top-level `version`, if present, is `"1.0"` | `Unsupported config version: 2.0` |
| `[shell] type` (case-insensitive) is zsh, bash or fish | `Invalid shell: unknown (must be zsh, bash, or fish)` |
| `[aliases]` names and commands (rules in [`[aliases]`](#aliases)) | `Invalid alias 'cd': Cannot use shell reserved word 'cd' as Alias name` |
| `[env]` names (rules in [`[env]`](#env)) | `Invalid constant 'MY-VAR': ...` |
| `[paths]` values: no `:`, newline or NUL | `Invalid path entry '/a:/b': Path cannot contain ':' or newlines (PATH separator)` |

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
top-level `shell = "..."` string is still read in place of `[shell] type`.

### `[paths]`

```toml
[paths]
local_bin = "~/.local/bin"
go_bin    = "$GOPATH/bin"
nm        = "./node_modules/.bin"
```

Each entry is `key = "directory"`.

- **Order is priority.** Entries go to the front of `PATH` in file order (the
  first entry wins). `wayu path add` appends; existing entries never move.
- **Keys are labels.** The shell never sees them; `wayu path rm <key>` and
  `wayu path add name=dir` use them. `path add` derives one when not given:
  lowercase, non-alphanumerics to `_`, `.local` to `hidden_local`, a generic
  basename (`bin`, ...) prefixed with its parent (`/usr/local/bin` to
  `local_bin`), `_2`, `_3` on collision.
- **Expansion happens in the shell**, at startup and at each re-sync: a
  leading `~` or `~/` becomes `$HOME`; `$NAME` and `${NAME}` expand (an
  `[env]` variable is already exported because `[env]` comes first). Nothing
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
  `$VAR` and relative arguments to an absolute directory, which must exist.
- **Integration with PATH:** wayu removes only directories it put on `PATH`
  itself (tracked in `_WAYU_PATHS_MANAGED`); a system directory that is also
  in `[paths]` is moved to wayu's position but never removed. In zsh the
  session also gets `typeset -U path`. In fish the dirs move to the front in
  `[paths]` order, like `fish_add_path -gpm`.

### `[aliases]`

```toml
[aliases]
ll          = "ls -lah"
onlead-logs = "tail -f /var/log/onlead.log"
gl          = 'git log --format="%h %s"'
```

Each entry is `name = "command"`.

| Rule | `toml validate`, `alias add`, TUI | Generator |
|---|---|---|
| Name characters | First an ASCII letter or `_`, then letters, digits, `_` or `-` (not first) | Any name without whitespace, quotes, `` ` `` `$ = ; & \| < > ( ) { } \ * ? [ ] # ~ !` or control characters; other names are skipped with a `# wayu: skipping invalid alias name` comment |
| Reserved names | `if then else elif fi case esac for while until do done in function time select coproc declare typeset local export readonly unset return exit cd pwd echo test true false` are refused | Not checked |
| Length | At most 255 characters | Not checked |
| Command | Must not be empty or blank | Emitted as given |

So a hand-written `".." = "cd .."` or `"g.st" = "..."` is defined by the
generated init and shown by `alias list`, but `toml validate` and `alias add`
refuse the name.

Generated code: zsh/bash `alias name='command'`, fish `alias name 'command'`.
The command is single-quoted and stored verbatim, so `$VAR` in it expands when
the alias runs. Aliases are emitted sorted by name, last in `core.<ext>`
(after plugins and tools), so an alias never breaks a function wayu or a
plugin defines.

### `[env]`

```toml
[env]
GOPATH = "$HOME/go"
GOBIN  = "${GOPATH}/bin"
```

Each entry is `NAME = "value"`, exported as `export NAME="..."` (zsh/bash) or
`set -gx NAME "..."` (fish), in file order, so a later value can use an
earlier one.

Names: an ASCII letter or `_`, then letters, digits or `_` (no `-`), not a
reserved word (list above), at most 255 characters. `toml validate` refuses
other names; the generator skips them with a comment. Lowercase names are
allowed (`const add` warns that the convention is `UPPER_CASE`). An empty
value (`X = ""`) is exported as empty.

**Expansion.** A leading `~` or `~/` becomes `$HOME`. Only references to
named variables expand; every other character, `$` included, is literal:

| Written | zsh / bash | fish |
|---|---|---|
| `$NAME` | expands (emitted as `${NAME}`, so `$HOME:h` or `$HOME[1]` are not zsh modifiers / subscripts) | expands |
| `${NAME}` | expands | expands |
| `${NAME<op>...}`, op = `-` `=` `+` `?` (each also with a leading `:`), `#`, `%`, `/` | expands, e.g. `${X:-d}`, `${X#pre}`, `${X/a/b}` | literal |
| `${#NAME}` | expands | literal |
| Any other `${...}`: `${X@P}`, `${X[1]}`, `${X:1}`, `${X: -2}`, `${X^}`, `${HOME:h}`, `${(e)X}` | literal | literal |
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
| `wayu const list` (text and `--json`, with or without `--full`) | `********` for secret-looking `[env]` values and environment variables; `--reveal` shows them |
| `wayu toml show` | The file with secret-looking `[env]` values as `********` (multi-line strings always masked; arrays / inline tables masked by name); `--reveal` prints the file verbatim |
| TUI constants view | Masked; `v` toggles reveal |
| Dry-run previews | Masked |
| `wayu const get NAME` | The real value |

Masking only affects display: `core.<ext>` holds and exports the real
values. Files holding `[env]` values (`wayu.toml` written by wayu, backups,
`core.<ext>`, `path_sync.<ext>`) are created owner-only (`0600`).

### `[settings]`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `autosuggestions_accept_keys` | array of strings | `["^Y", "^[[121;5u"]` | zsh only. Key sequences bound to `autosuggest-accept` (zsh-autosuggestions) in the `main`, `emacs` and `viins` keymaps. Entries must start with `^` or contain `[`; others, non-strings, empties and duplicates are ignored. An empty or missing array uses the default. The array may span lines. |

The bindings are written to `<data>/plugins/config.zsh`, which `core.zsh`
sources after the plugins; they apply only when the `autosuggest-accept`
widget exists. No other `[settings]` key is read.

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
are ignored. Entries are emitted sorted by name (not file order).

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

- Expand: `$NAME` / `${NAME...}` (same rules as [`[env]`](#env)) outside
  single quotes, and a leading `~` / `~/`.
- Literal: everything else, including `{a,b}` (no brace expansion).
- Refused: a newline, `;` `&` `|` `<` `>` `(` `)`, `$(...)`, backticks,
  unquoted glob characters `*` `?` `[`, and a word that mixes quoted and
  unquoted `$`. `wayu build` exits `78` naming the tool
  (`ERROR: wayu.toml [tools] foo: args contains the shell operator ";"`);
  other regenerations skip the tool with a warning on stderr.

For example `args = 'init "$HOME/x y" ~/z {a,b}'` generates
`_wayu_evalcache foo init "${HOME}/x y" "${HOME}/z" '{a,b}'`.

**fish.** `[tools]` load in fish too. In `args`, a word `zsh` or `bash`
becomes `fish` and `--zsh` / `--bash` becomes `--fish`, so
`args = "init zsh"` runs `zoxide init fish`.

**Where they load** (see [Load order](#load-order)): eager evalcache tools
before the prompt and plugins; all other non-login tools ("deferred") after
the plugins; `login_only` tools after `tools.<ext>` and `extra.<ext>`.
"Deferred" is a position in the file, not a key, and not zsh-defer.

### `[prompt]`

A native zsh prompt, off by default. It is generated only for zsh, only when
`[prompt] enabled = true`, and set up only in interactive shells. bash and
fish ignore the whole table.

The `[prompt]` tables are read line by line, not with the TOML parser:

- Each header must be exactly `[prompt]`, `[prompt.username]`, ... on its own
  line: `[prompt] # mine` or `[ prompt ]` is not recognised (and the prompt
  stays off).
- Each key and value must be on one line; `[prompt.contexts]` entries are
  one-line inline tables.
- `enabled` and `vi_mode` must be the bare word `true` (a trailing `# comment`
  is fine).

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
| `vimcmd_replace_symbol` | string | `❮` | vi replace mode. |

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
| `async_rprompt` | boolean | `true` | Background job after each command: git changed-file count (right prompt) and context version. |
| `rprompt_format` | string | `"[ {git_pending}](242)"` | Right prompt, shown when the work tree has changes. `{git_pending}` = number of changed files, `{git_branch}` = branch. |

### Keys wayu does not read

These parse without error but have no effect: `wayu_version`; `[settings]`
`auto_backup`, `fuzzy_fallback`, `dry_run_default`; `[path] dedup` /
`[path] clean`; `[[plugins]]` (plugins live in `plugins.json`); `[profile.*]`;
`[prompt.username] style_user`; `[prompt.interactive]` `async_interval`,
`transient_format`; any table not listed above.

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

Format: one `event = command` per line; `#` starts a comment line; one
matching pair of quotes around the whole command is removed; unknown keys
are ignored; for a repeated key the last line wins.

| Event | `{path}` | `{name}` | `{value}` |
|---|---|---|---|
| `pre_path_add`, `post_path_add` | directory | | |
| `pre_path_remove`, `post_path_remove` | directory (also when removed by key) | | |
| `pre_alias_add`, `post_alias_add`, `pre_alias_remove`, `post_alias_remove` | | alias name | command |
| `pre_constant_add`, `post_constant_add`, `pre_constant_remove`, `post_constant_remove` | | variable name | value |
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

Hooks run with `sh -c`; their exit status is ignored. Pre-hooks run only when
the operation will change something, post-hooks only after a successful
write, and none under `--dry-run`. In the TUI a hook is stopped after 30 s.

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
      "installed_path": "/home/me/.config/wayu/plugins/zsh-autosuggestions",
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
| `plugins[].name` | string | Plugin name: one path component, not starting with `-`. |
| `plugins[].display_name` | string | Alternative name accepted by `plugin get/enable/...`. |
| `plugins[].url` | string | Clone URL (validated). |
| `plugins[].source_type` | enum | `GitHub`, `GitLab`, `Gist`, `Git`, `Remote`, `Local`. |
| `plugins[].enabled` | boolean | Only enabled plugins load. |
| `plugins[].shell` | enum | `ZSH`, `BASH`, `BOTH` (zsh + bash), `FISH`, `ANY` (all three). |
| `plugins[].installed_path` | string | Clone dir; no leading `-`, no control characters. |
| `plugins[].use` | array of strings | Files to source, matched at the repository root: exact names or one-`*` globs (`"*.plugin.zsh"`). Set with `wayu plugin add <url> --use <file-or-glob>` (repeatable). Empty: auto-detect (below). |
| `plugins[].template` | enum | How each file is loaded: `Source` (`source file`), `Path` (prepend the plugin dir to `PATH`), `FPath` (prepend to `FPATH`), `Autoload` (`autoload -Uz name`), `Eval` (`eval "$(file)"`). |
| `plugins[].git` | object | `ref_type` (`Branch`, `Tag`, `Commit`), `branch`, `tag`, `commit`, `pinned_ref`, `last_checked`, `remote_commit`. Refs are validated. |
| `plugins[].dependencies` | array of strings | Plugin names loaded before this one. Must be valid plugin names; a cycle is an error. A missing or disabled dependency is noted as a comment in `plugins.<ext>`. |
| `plugins[].priority` | integer | Load order among plugins whose dependencies are met; lower loads earlier (default 100). Ties keep file order. |
| `plugins[].conflicts` | object | Written by wayu's conflict detection. |
| `plugins[].entry_file`, `plugins[].profiles` | | Not used. |

Enum values are matched case-insensitively; integers (the format up to
4.4.5) are accepted too. Any invalid value makes every command that reads
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

`$WAYU_CONFIG_DIR/functions/` holds one file per function
(`wayu function add <name>` writes `functions/<name>.<ext>`). Sourced at
startup:

| Shell | Sources |
|---|---|
| zsh | Every regular file except `*.bash` and `*.fish` |
| bash | Every regular file except `*.zsh` and `*.fish` |
| fish | `*.fish` only |

### completions/

`$WAYU_DATA_DIR/completions/` (`wayu completions add` / `generate` write
here):

| Shell | Used as |
|---|---|
| zsh | Prepended to `fpath` (files named `_<command>`); `compinit` runs in interactive shells and rebuilds `.zcompdump` when the dir's file list changes |
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
| `init.<ext>` | Entry point your rc file sources: loads `core.<ext>` (prints a hint to run `wayu build` when it is missing). Written by `wayu init`. An unmodified copy is replaced when the template changes (backup first); an edited one is kept, with a warning. |
| `core.<ext>` | Everything `init.<ext>` loads, precomputed from `wayu.toml` (zsh also `core.zsh.zwc`, compiled in the background). |
| `path_sync.<ext>` | The `[paths]` list; line 1 is its signature. The prompt hook re-sources it when the signature changes. |
| `turbo.<ext>` | zsh/bash. Same content as `core.<ext>`, refreshed with it, only if it exists (created by `wayu export`). |
| `plugins.<ext>` | Plugin loader, regenerated on any `plugin` change and by `wayu init`. |
| `plugins/config.zsh` | `[settings] autosuggestions_accept_keys` bindings. |
| `backup/` | Timestamped backups, 5 newest per file (see `wayu backup`). |

Also `$WAYU_CONFIG_DIR/.wayu.lock` (lock shared by concurrent wayu commands)
and the evalcache under `${XDG_CACHE_HOME:-~/.cache}/wayu/evalcache`. Older
versions' `lazy.<ext>`, `login.<ext>` and `helpers.<ext>` are deleted on
regeneration.

## Load order

`core.zsh` / `core.bash`, each `# === ... ===` line a section:

1. `WAYU_CONFIG_DIR` / `WAYU_DATA_DIR` exports (only when not default)
2. `[env]`
3. `[paths]` (and the live PATH sync hook)
4. Completions (zsh: `fpath`, `compinit` in interactive shells)
5. `functions/`
6. `config.<ext>` content
7. Helpers (evalcache; zsh: zsh-defer, `wayu_compile`)
8. Eager `[tools]`
9. Native prompt (zsh, interactive, `[prompt] enabled = true`)
10. Plugins (`plugins.<ext>`; zsh: `plugins/config.zsh`)
11. Deferred `[tools]`
12. `tools.<ext>`
13. `extra.<ext>`
14. Login-only `[tools]`
15. `[aliases]`

`core.fish`: directory exports, `[env]`, `[paths]`, completions,
`functions/*.fish`, `config.fish` content, evalcache helper, eager `[tools]`,
`plugins.fish`, deferred `[tools]`, login-only `[tools]`, `[aliases]`. No
native prompt. `init.fish` then sources `tools.fish` and `extra.fish`.
