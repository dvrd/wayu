# wayu CLI reference

```
wayu                                   # interactive TUI
wayu <command> [<action>] [arguments] [flags]
```

Every command, action word, command flag and `--json` support listed here
comes from one table in the source, `WAYU_COMMAND_SPECS`
(`src/wayu_completions.odin`), which also drives dispatch, `wayu help` and
wayu's own shell completions. `tests/unit/test_cli_doc.odin` fails when this
file misses a command, alias, action or flag from that table, and
`tests/integration/test_exit_codes.rb` runs the [exit code
examples](#exit-code-examples) below.

The config file format is described in [config-reference.md](config-reference.md);
behavior changes between releases in [UPGRADING.md](UPGRADING.md).

- [Global flags](#global-flags)
- [Where flags are recognised](#where-flags-are-recognised)
- [Commands](#commands)
- [JSON output](#json-output)
- [Exit codes](#exit-codes)
- [Environment variables](#environment-variables)

## Global flags

| Flag | Meaning |
|---|---|
| `--dry-run`, `-n` | Show what would change; write nothing |
| `--yes`, `-y` | Confirm a destructive operation (see below) |
| `--json` | Machine-readable output; only where listed in [JSON output](#json-output), elsewhere exit `64` |
| `--no-color`, `--no-colour` | No ANSI escape codes (same as `NO_COLOR=1`) |
| `--shell <zsh\|bash\|fish>` | Act on this shell's files instead of the one detected from `$SHELL` |
| `--full`, `-f` | `path`/`alias`/`const list`: include external entries (same as `--source all`); elsewhere exit `64` |
| `--source <filter>`, `--source=<filter>` | `path`/`alias`/`const list`: `wayu` (default), `inactive`, `external` or `all`; elsewhere exit `64` |
| `--tui` | Open the TUI (same as running `wayu` with no arguments) |
| `--help`, `-h`, `help` | Global help, or a command's help after the command (`wayu path --help`) |
| `--version`, `-v`, `version` | Print `wayu vX.Y.Z` |
| `--` | End of flags: every later word is a literal argument |

`--yes` is required by `path clean`, `path dedup`, `backup restore`,
`backup remove`, `plugin remove`, `function remove`, `script remove` and
`config scan --fix`
whenever they would change something, and always by `doctor --fix` (unless
`--dry-run`); without it they print what would happen and exit `64`.

Developer flags (golden-file tests, see AGENTS.md): `-c=<component>` (only
before any command word), `--test`, `--snapshot` (only with `-c=`; else exit
`64`). Their `width=N` / `height=N` must be 1-1000 (else exit `64`).

Human-readable output never prints a control character from your data raw:
in `path`/`alias`/`const list`, `plugin list`/`get`/`search`, `script list`,
`search` and `doctor`, a tab is shown as `\t`, a newline as `\n`, other
control characters (C0, DEL) and bytes that are not valid UTF-8 as `\xHH`, and
C1 controls (U+0080-U+009F) as `\u00HH`. `--json` output and `const get`,
`alias get`, `path get` print values exactly as stored.

An action that takes no arguments (`list`, `secrets lock`, `toml validate`,
every `export` mode, ...) exits `64` on an extra word after it.

## Where flags are recognised

1. `--` ends flag parsing. Everything after it is a literal argument and
   the `--` itself is dropped: `wayu alias add g -- -n` stores `-n`.
2. In `alias add` and `constants add` (`const`, `env`), once the name and the
   first value word have been given, the rest of the line is the value,
   dashes included: `wayu alias add gpf git push -f` stores `git push -f`.
   Flags may still come before the first value word
   (`wayu alias add -n gc 'git commit'`). A dash word right where the value
   starts is the value: `wayu const add OFFSET -5`.
   Exception: `--dry-run`, `--yes`, `--json` and `--no-color` (and, for
   `constants add`, `--secret`) at the very end of the line are flags
   (`wayu alias add gpf git push -f --dry-run` previews). To keep them in the value, put `--` before it:
   `wayu alias add hd -- helm install --dry-run`. A trailing `-n` or `-y`
   stays in the value with a warning on stderr.
3. Anywhere else a global flag may appear in any position.
4. Any other `-x` / `--xyz` word must be a flag of that command (listed per
   command below), else wayu exits `64` (`Unknown option`) before doing
   anything — a typo like `--dryrun` never performs a real write. A word
   like `-5` is a number, not a flag (`plugin priority NAME -5`).

## Commands

An action word a command doesn't have exits `64` with that command's help.
`wayu <command> help` (or `-h` / `--help`) prints the command's help.
A `get` / `rm` of a name that does not exist exits `65` and lists similar
names on stderr; it never acts on a guess.

### `wayu path`

Manage PATH entries (stored in `<data>/entries.json`, see
[config-reference.md](config-reference.md#managed-data)). Default action: `list`.

| Action | Arguments | |
|---|---|---|
| `add` | `<dir>` or `<key>=<dir>` | Add a directory (must exist, else exit `66`; a file that is not a directory exits `65`; `~` and relative paths are resolved). The key defaults to the directory's base name; an existing directory is left as is (exit `0`) |
| `remove`, `rm` | `<dir-or-key>` | Remove an entry by directory or key |
| `list`, `ls` | | List entries (`--json`, `--full`, `--source`) |
| `get` | `<dir>` | Print the entry (exact directory) |
| `clean` | | Remove entries whose directory no longer exists (`--yes`) |
| `dedup` | | Remove duplicate entries (`--yes`) |
| `help` | | |

```bash
wayu path add ~/.cargo/bin
wayu path list --full
wayu path clean --dry-run
```

### `wayu alias`

Manage aliases (stored in `entries.json`). Default action: `list`. Names:
printable ASCII except whitespace, quotes, `$` `` ` `` `\` `=` `/` `^` `;` `&`
`|` `<` `>` `(` `)` `{` `}` `[` `]` `*` `?` `#` `~` `!`, not starting with `-`
(so `..`, `g.st`, `1x`, `k8s-ctx` work). Command names may be aliased
(`alias add cd z`); shell grammar words (`if`, `do`, `function`, ...),
declaration builtins (`local`, `export`, `typeset`, `return`, ...), `.` and
names starting with `_wayu` (wayu's own helpers) are refused (exit `65`). The same rule applies to names in `entries.json`.

| Action | Arguments | |
|---|---|---|
| `add` | `<name> <command...>` | Add or replace an alias |
| `remove`, `rm` | `<name>` | |
| `list`, `ls` | | `--json`, `--full`, `--source` |
| `get` | `<name>` | Print the alias's command |
| `help` | | |

### `wayu constants` (`const`, `env`)

Manage constants: exported environment variables (stored in
`entries.json`). Default action: `list`. Names: ASCII letters, digits and
`_`, not starting with a digit. Protected names exit `65`: `PATH`, `path`,
`FPATH`, `fpath`, `HOME`, `IFS`, `SHELL`, `USER`, `LOGNAME`, `PWD`,
`OLDPWD`, `ZDOTDIR`, `SHLVL`, `_`, every `WAYU_*` name (setting them from
wayu breaks the shell or wayu), and names whose value a shell runs as code
or loads code from: `PS0`-`PS4`, `PROMPT`, `prompt`, `PROMPT2`-`PROMPT4`,
`RPROMPT`, `RPROMPT2`, `RPS1`, `RPS2`, `SPROMPT`, `PROMPT_EOL_MARK`,
`PROMPT_COMMAND`, `BASH_ENV`, `ENV`, `fish_function_path`,
`fish_complete_path`. `wayu doctor` reports stored ones as an error. A value (alias command, constant value, PATH dir) with a NUL byte or
invalid UTF-8 exits `65`.

| Action | Arguments | |
|---|---|---|
| `add` | `<NAME> <value...>` | Add or replace a variable |
| `add` | `<NAME> [value...] --secret` | Store the value encrypted (see [`wayu secrets`](#wayu-secrets-secret)) |
| `remove`, `rm` | `<NAME>` | Plain or encrypted |
| `list`, `ls` | | `--json`, `--full`, `--source`, `--reveal` |
| `get` | `<NAME>` | Print the real value (exact name only; decrypts a secret) |
| `help` | | |

| Flag | |
|---|---|
| `--reveal` | `list`: show secret-looking values instead of `********` (never encrypted ones) |
| `--secret` | `add`: encrypt the value into `secrets.json` instead of storing it in `entries.json` |
| `--run-only` | `add`: like `--secret`, but the shell never exports it; only the `secrets run` action injects it |

`get` is safe in scripts: `X=$(wayu const get NAME)` either gets that
variable's value or fails with exit `65`, also when `entries.json` marks
NAME secret but `secrets.json` has no value for it (`wayu doctor` reports
that as an error, and a value in `secrets.json` with no secret entry in
`entries.json` as a warning).

`add --secret`: without a value, it is read from stdin (hidden when stdin is
a terminal; one trailing newline is dropped), so it stays out of argv and
shell history: `wayu const get OLD | wayu const add NEW --secret`. A value
given as an argument is accepted with a warning on stderr (other local users
can read argv with `ps`, and it lands in shell history). Like
`--dry-run`, a `--secret` at the end of the line is a flag, not part of the
value. An existing plain constant is converted (its `entries.json` entry
keeps its place, without the value). A plain `add` of a name that is a secret exits `65`; `--secret`
on any other action exits `64` (`--run-only` likewise). Hooks receive an
empty `{value}` for secrets. `list` shows secrets as `********` with source
`wayu (secret)` (`wayu (secret, inactive)` when not in this shell's
environment; the same strings in `--json`), run-only ones with
`wayu (run-only)`. Re-adding a secret
with `--secret` or `--run-only` switches its mode.

### `wayu search` (`find`, `f`)

`wayu search <query>`: fuzzy search over PATH entries (directory or key;
the result shows the directory), alias names
and constant names (never values: not alias commands, not constant values).
Results show the value, masked like `const list`; an encrypted constant
shows `********`. Match types: exact, prefix, substring,
acronym (first letters of the words: `faak` → `FIREWORKS_AI_API_KEY`), fuzzy. Supports `--json`.
Without a query it prints its help and exits `64`.

### `wayu completions`

Completion scripts in the data dir's `completions/`. Default action: `list`.

| Action | Arguments | |
|---|---|---|
| `add` | `<name> <file>` | Copy a completion script in |
| `remove`, `rm` | `<name>` | |
| `list`, `ls` | | |
| `generate` | | Write wayu's own zsh, bash and fish completions |
| `zsh`, `bash`, `fish` | | Print wayu's completion script for that shell |
| `fpath` | `[list]`, `add <dir>`, `rm <dir>` | zsh: completion dirs wayu puts on `fpath` before `compinit` (entries.json `fpath`; `wayu optimize` fills it). `add` puts the dir first; a dir with `:`, a newline or a glob character (`* ? [ ] ( ) < > \| # ^ ~`, except a leading `~`) is refused |
| `help` | | |

wayu's own completions parse the line rather than count positions: global
flags (with their values) may come anywhere, command flags complete at any
position after the command, and `--` ends the flags. Besides commands,
actions and flags they offer the values of `--shell`, `--source`, `--lang`,
`--category`/`-c`, `--template`, existing entries for `rm`/`get`/... ,
`backup list|restore|rm` types and `backup restore <type>` numbers,
`template apply` and `plugin add` names, `secrets run` secret names and,
after `--`, the command. Run `generate` again after upgrading wayu.

### `wayu backup`

Default action: `list`. wayu backs a file up before changing it (once per
command) and keeps the newest 5 per file in `backup/`.

| Action | Arguments | |
|---|---|---|
| `list`, `ls` | `[type]` | All backup groups (wayu.toml, entries.json, plugins.json, the rc file, …); `--json` |
| `restore` | `<type> [N\|file]` | Restore the file `type` names from the newest backup, backup #N, or a file (`--yes`) |
| `remove`, `rm` | `[type]` | Prune to the newest 5 (`--yes`) |
| `help` | | |

`type` is `toml` (wayu.toml) or `entries` (entries.json); `path`, `alias`
and `constants` also name entries.json, so a restore reverts all PATH
entries, aliases and constants together. A shell startup file (zsh, bash or
fish; what `wayu optimize` rewrites) is named as `backup list` shows it
(`.zshrc`, `~/.config/zsh/.zshrc`) or by its path. The current file is backed
up first.

Each entries.json backup keeps a copy of `secrets.json` (ciphertext only) as
it was at that moment, in `backup/secrets/`; restoring entries.json restores
`secrets.json` with it (or removes it when there was none), so secret
constants and their values stay paired. Backups without that copy (taken
before this, or before a `secrets rekey`, which drops the copies: their
values were encrypted with the old key) restore entries.json only.

### `wayu plugin`

Default action: `list`. `<name>` must match an installed plugin exactly.

| Action | Arguments | |
|---|---|---|
| `add` | `<registry-key-or-git-url>` | Clone and enable a plugin |
| `remove`, `rm` | `<name>` | Uninstall (`--yes`) |
| `list`, `ls` | | `--json` |
| `get` | `<name>` | Show details |
| `search` | `[query]` | Browse the built-in registry |
| `enable`, `disable` | `<name>` | |
| `priority` | `<name> <number>` | Load order, lower first (default 100) |
| `check` | | Check for updates |
| `update` | `<name>` or `--all` | Fast-forward to the remote |
| `help` | | |

| Flag | |
|---|---|
| `--all`, `-a` | `update`: every plugin |
| `--category <c>`, `-c <c>`, `--category=<c>` | `search`: filter by category |
| `--use <glob>`, `--use=<glob>` | `add`: file(s) to load from the repository root (repeatable) |

### `wayu init`

`wayu init [--template <name>]`: create the config dir
(`~/.config/wayu`) and the data dir (`${XDG_DATA_HOME:-~/.local/share}/wayu`),
a `wayu.toml` scaffold and `init.<ext>`, generate the init files, and offer
to add this line to your rc file (only when stdin is a terminal; otherwise it
prints the line):

```sh
source "${WAYU_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/wayu}/init.zsh"
```
 Safe to re-run: existing files are kept and an
unmodified `init.<ext>` from the previous release is updated. `--shell` picks the shell.

| Flag | |
|---|---|
| `--template <name>`, `--template=<name>` | Then apply a template (see `wayu template list`) |

### `wayu config`

Without an action it prints its help.

| Action | |
|---|---|
| `edit` | Open wayu.toml in `$VISUAL` / `$EDITOR` (else `vi`), then regenerate |
| `extend` | Open `extra.<ext>` (shell code sourced at the end of init) |
| `scan` | Find tool-init blocks in the current shell's rc file (zsh: `$ZDOTDIR/.zshrc` when set) that could move to `extra.<ext>`, including `# >>> … # <<<` installer blocks |
| `help` | |

| Flag | |
|---|---|
| `--fix` | `scan`: append the blocks found to `extra.<ext>` of the same shell (`--yes`); the rc file is left as is (`wayu optimize` moves lines and removes them) |

### `wayu build`

| Action | |
|---|---|
| *(none)* | Regenerate the init files from wayu.toml and entries.json (after a hand edit), and `plugins.<ext>` from plugins.json, for every set-up shell. Exit `78` when plugins.json is invalid (the plugin loaders are left as they were; everything else is regenerated) or a `[tools]` entry's `args` is unusable |
| `turbo` | Same as `wayu export --turbo` |
| `profile` | Time shell startup and each section, tool and plugin of `core.<ext>`. core is timed in an interactive shell whose only rc file sources it (zsh: `ZDOTDIR` set to a private temp dir; bash: `--rcfile`; fish: `-i --no-config`), so compinit, the prompt and plugins count; the per-unit breakdown needs zsh or bash 5+ |
| `clean` | Delete the `[tools]` evalcache (`${XDG_CACHE_HOME:-~/.cache}/wayu/evalcache`) |
| `help` | |

### `wayu export`

Default action: `turbo`. Each action may also be written as a flag
(`--turbo`, `--eval`, `--check`).

| Action | |
|---|---|
| `turbo` | Write `turbo.<ext>`, a copy of `core.<ext>` (fish: `core.fish` followed by `tools.fish` and `extra.fish`, like `init.fish`) |
| `eval` | Print constants, PATH entries and aliases as shell code for `eval "$(wayu export --eval)"` (fish: `wayu export --eval \| source`; writes nothing). Keep the double quotes: an unquoted `eval $(…)` glob-expands the output against the current directory, so a crafted file name there can run code |
| `check` | Exit `0` if `turbo.<ext>` is current — its content is exactly what `export --turbo` would write now (any input: wayu.toml, entries.json, `config.<ext>`, a newer wayu) — `78` if it is missing or stale |
| `list`, `ls` | Show the formats |
| `help` | |

### `wayu toml`

| Action | |
|---|---|
| `validate` | Strict check of wayu.toml (syntax, duplicate keys, `[shell] type`, table shapes, no `[paths]` / `[aliases]` / `[env]`); exit `65` on error. Keys wayu does not read are warnings (exit `0`) |
| `show` | Print wayu.toml |
| `keys` | List wayu.toml's top-level keys and tables, in file order; exit `65` if it does not parse |
| `help` | |

Without an action, `wayu toml` behaves like `wayu toml validate`.

### `wayu doctor`

Health checks: installation, rc file, PATH entries, plugins and plugin
conflicts, backups, wayu.toml (a `[paths]`, `[aliases]` or `[env]` table is an
error naming the `wayu path|alias|const add` command), entries.json (must
parse), scripts (error: two sources for one name or a CRLF shebang; warning:
stale or broken builds), script bin entries (`bin/` entries without a script;
`--fix` removes them),
turbo file, dependencies, startup files (lines `wayu optimize` would move,
a second `compinit` counts ~250 ms; generator commands are listed, never
run: doctor does not execute rc file content), directory permissions (a config/data
dir, or a subdir of them two levels deep, symlinks not followed, that is
group- or other-writable is an error: another user could change startup code
or put commands in `bin/`; wayu creates its dirs `0700` whatever the umask).
Exits `78` when any
check reports an error (warnings don't), so it can gate CI. Supports `--json`.

| Flag | |
|---|---|
| `--fix` | Remove missing / duplicate PATH entries, run `wayu optimize`, remove group/other write from wayu dirs (`--yes`, or `--dry-run` to preview) |
| `--profile` | Write a zsh startup profiler script to `<data>/startup_profile.zsh` (see also `wayu build profile`); exits `64` with `--json` or `--fix` |
| `--optimize` | Removed; prints a pointer to `wayu build` / `wayu export` and exits `64` |

### `wayu template`

Default action: `list`. Templates: `developer`, `minimal`, `data-science`,
`full`.

| Action | Arguments | |
|---|---|---|
| `list`, `ls` | | |
| `apply` | `<name>` | Add the template's entries; existing ones are kept, PATH dirs missing on this machine (or not directories) are skipped |
| `help` | | |

### `wayu hooks`

Default action: `list`. Hooks are configured in `hooks.conf`
([config-reference.md](config-reference.md)).

| Action | |
|---|---|
| `list`, `ls` | Show configured hooks |
| `edit` | Open `hooks.conf` in the editor |
| `help` | |

Hooks run outside wayu's config lock (so they may run `wayu`), with their
output shown, and are killed after 30 s (`timeout` in `hooks.conf`).

### `wayu function` (`functions`, `func`, `fn`)

Shell functions as files in the data dir's `functions/` (sourced by
`core.<ext>`, so they can change the shell's state). Default action: `list`.

| Action | Arguments | |
|---|---|---|
| `add`, `new`, `edit` | `<name>` | Create (from a skeleton for the shell, mode `0600`) or open the function file in the editor; without `$EDITOR` / `$VISUAL` and a terminal, print its path instead. A dangling symlink at the path exits `73` |
| `list`, `ls` | | |
| `remove`, `rm`, `delete` | `<name>` | Delete the file (`--yes`) |
| `help` | | |

### `wayu script` (`scripts`)

Standalone executables in any language, on PATH. Sources live in the data
dir's `scripts/` (the directory is the list: `NAME.<ext>`); what runs is
`bin/NAME`, and `core.<ext>` puts the data dir's `bin/` first among wayu's
PATH entries (once it holds a script) in zsh, bash and fish. Interpreted
scripts are linked (`bin/NAME` → `../scripts/NAME.<ext>`, source `0755`);
compiled ones are built into `bin/NAME` (swift: `swiftc -O`, or any build
command a source declares, below). Default action: `list`.

| Action | Arguments | |
|---|---|---|
| `new` | `<name> [--lang <lang>]` | Create `scripts/<name>.<ext>` from a skeleton, open it in the editor, build it. Exit `65` if the name exists or anything (a symlink too) is at that path |
| `edit` | `<name>` | Open the source in the editor, then rebuild it if it changed |
| `list`, `ls` | | Name, language, state, source; `--json` |
| `remove`, `rm` | `<name>` | Delete the source (backed up first) and its `bin/` entry (`--yes`); a `bin/` entry without a script is removed alone |
| `import` | `<file>...` | Move existing scripts in (`--copy` keeps the originals; `--allow-build` runs build commands they declare; `--dry-run` previews) |
| `build` | `[<name>...]` | Build every stale script, or the ones named |
| `help` | | |

| Flag | |
|---|---|
| `--lang <lang>`, `--lang=<lang>` | `new`: `swift`, `python`, `ruby`, `node` (`.js`), `bun` (`.ts`), `bash`, `zsh`, `fish`, `perl`, `lua`, `sh`. Default: `[scripts] default_lang` in wayu.toml, else `swift`. An unknown value exits `64` |
| `--copy` | `import`: keep the original files |
| `--allow-build` | `import`: import files that declare their own build command (below), which wayu then runs now and on every rebuild. Without it such a file makes `import` exit `64` before anything is imported or run (a language preset such as swift's `swiftc -O -o {out} {src}` needs no flag) |

Names: ASCII letters, digits, `_`, and `-` after the first character.

`new` writes a shebang with the absolute path of the interpreter found on
PATH at that moment (`#!/opt/homebrew/bin/python3`); when it is missing
(for swift: `swiftc`) it exits `69` naming it. Without `$EDITOR` /
`$VISUAL` and a terminal it prints the new file's path instead of opening
an editor.

Build commands: a source in any language may declare how it is built in a
comment line (`//`, `#`, `--`, `;`, `/*`, `*`) among its first 20 lines:

```c
// wayu: build = cc -O2 -o {out} {src}
```

`{src}` is the source, `{out}` the file the command must write (it becomes
`bin/NAME`; a command without `{out}` is refused). The words are split like a
shell would (quotes, backslashes; no expansions or pipes) and run without a
shell, in the data dir's `scripts/` (never the directory wayu was started
in); the first word is looked up on PATH. Such a source may have any
extension (`tool.c` → `tool`). Swift's `swiftc -O -o {out} {src}` is the same
mechanism as a preset, used when a swift source declares none.

Python with inline dependencies ([PEP 723](https://peps.python.org/pep-0723/))
runs through [uv](https://docs.astral.sh/uv/) without a build: give the
script the shebang `#!/usr/bin/env -S uv run --script` and a `# /// script`
block (it is a python script: `uv` in a shebang is recognised on import):

```python
#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["requests"]
# ///
import requests
```

Two sources with the same name (`foo.sh`, `foo.rb`) are an error: neither
is built (`script build` exits `1`), `edit` / `build` / `rm` of that name exit
`65`, and doctor reports it. A source whose shebang line ends in CR (CRLF line
endings; it could only fail with `bad interpreter`) is not linked and doctor
reports it; `import` converts such a file to LF.

A compiled script is stale when its source or build command no longer
matches the hash stored in `bin/.NAME.hash` (or the binary is missing); an
interpreted one when its link is missing or wrong. `wayu build`, `wayu reload` (which also
watches the sources) and `script build` rebuild stale scripts (the
`wayu build` that the prompt hook runs starts a background `script build`
instead of waiting for the compiler). A failed
compile prints the compiler's output, exits `1` and keeps the previous
binary.

`import` takes regular text files with a `#!` line, a known extension or a
build command header. The language comes from the shebang's interpreter
(`#!/usr/bin/env X` is read as `X`, skipping env's options and their
arguments: `-u VAR`, `-P dir`, `-C dir`, `--unset=VAR`; trailing version
digits are ignored: `python3.12` → python),
else from the extension. The file keeps its shebang and a known extension
(else gets the language's); a file without a shebang gets one for the
interpreter on PATH. It skips, with the reason: symlinks, binaries (NUL
byte or Mach-O/ELF header in the first 4 KiB), launchers generated by
package managers (shebang inside a venv, pipx or uv tool dir, or a
`console_scripts` stub `from X import F … sys.exit(F())`), wrappers whose
only command is `exec "/abs/path" "$@"` (`launcher for /abs/path`), unknown
interpreters and names that already exist. A file with a `wayu: build =`
header shows the command (`[build: …]`) in `--dry-run` and in the summary;
unless it is a language preset it needs `--allow-build`. Each file is copied and built
before the original is removed; one that fails to build is skipped and left
in place. A summary lists what was imported and skipped; exit `65` when
nothing was imported.

```bash
wayu script new hello --lang python
wayu script import ~/bin/* --dry-run
wayu script list --json
```

### `wayu secrets` (`secret`)

Encrypted constants. `wayu const add NAME [VALUE] --secret` stores the value
encrypted (ChaCha20-Poly1305, AAD = the name) in the data dir's
`secrets.json` (`0600`); the 256-bit master key lives in the
[`[secrets] backend`](config-reference.md#secrets) (macOS keychain, Secret
Service, or `secret.key` in the config dir). `const get` decrypts,
`const rm` removes. Default action: `list`.

| Action | Arguments | |
|---|---|---|
| `list`, `ls` | | Secret names and mode (`session` or `run-only`), one per line (never values) |
| `rekey` | | New master key, re-encrypt every secret, drop the session cache |
| `lock` | | Delete the decrypted session cache from every dir it was written to (next shell decrypts again) |
| `run` | `<NAME>... -- <cmd> [args...]` | Run `cmd` with these secrets in its environment |
| `identity` | `[--name NAME]` | (experimental) Print this machine's age recipient (`age1…`) on stdout, creating its identity the first time; stderr shows the `recipient add` command to run on a machine that reads the secrets (`--name`: the name in that command, default `hostname -s`; `NAME` when the hostname is empty or an IP address) |
| `recipient` | `list` (`ls`) `[--json]` · `add <age1…> [--name NAME]` · `rm <NAME> --yes` · `rename <OLD> <NEW>` | (experimental) Machines that can read the secrets (see below) |
| `adopt` | `--yes` | (experimental) Accept the data key in this machine's stanza without a rotation proof: a new machine's first step (prints the fingerprint to compare). Never a key this machine replaced. On a version 1 file this machine knew as version 2: back to one machine |
| `recovery` | `add [--name NAME]` · `rm --yes` · `unlock` | (experimental) Recovery passphrase (read from stdin, never argv) |
| `help` | | |

**Run-only secrets.** `wayu const add NAME [VALUE] --run-only` stores a
secret that shells never export: it is not in the session cache,
`core.<ext>`, `turbo.<ext>` or `export --eval`. `wayu secrets run NAME... --
CMD [ARGS...]` decrypts the named secrets (run-only or not) and replaces
itself with `CMD` (looked up on `PATH`, no shell, no extra process), its
environment being wayu's plus those variables, so the exit status and
signals are `CMD`'s own. Values are never printed; `--dry-run` prints the
names and the command. Exit `64` without `--`, names or a command; `65` for
a name that is not a secret; `127` when `CMD` is not found; `126` when it
cannot be executed. The run-only mark is bound into the encryption (AAD), so
editing it out of `secrets.json` makes the value undecryptable instead of
exporting it. Typical use, an alias that gives one tool its token:

```bash
wayu const add GH_TOKEN --run-only            # value from stdin
wayu alias add gh 'wayu secrets run GH_TOKEN -- gh'
```

Shells never read plaintext from the data dir: `core.<ext>` sources a
per-login-session cache, `${XDG_RUNTIME_DIR:-${TMPDIR:-<data>/run}}/wayu-<uid>/secrets-<id>.<ext>`
(`0600` in a `0700` dir owned by you; `<data>/run/wayu-<uid>` when that dir
is a symlink, not yours, or open to group/other; a symlinked cache file is
never sourced), when it is newer than
`secrets.json`; otherwise it runs `wayu secrets cache` once (a hidden helper
that decrypts into that file). When the key is unavailable or a value does
not decrypt, the shell prints one `wayu: secrets not loaded: …` line on
stderr and starts without the secrets. The first `add --secret` creates the
key; wayu never creates a new key while `secrets.json` holds values (exit
`78`). Errors reading the store or key exit `78`; write errors `74`.

#### Multi-machine secrets (experimental)

The same `secrets.json` (with `entries.json`) can be read on several
machines without copying any key between them. Each machine has its own age
X25519 identity (`AGE-SECRET-KEY-1…`, kept by the `[secrets]` backend), and
`secrets.json` version 2 wraps one data key to every machine's recipient
(`age1…`); see [config-reference.md](config-reference.md#multi-machine-secrets-experimental).
Experimental: these actions and the version 2 format may change in a minor
release (a format change still migrates automatically). The first use prints
a one-time notice on stderr.

```bash
wayu secrets identity                              # on the new machine B: prints age1…
wayu secrets recipient add age1… --name linux-box  # on machine A: prints the data key fingerprint
# sync secrets.json (and entries.json) to B, then on B:
wayu secrets adopt --yes                           # prints the same fingerprint: compare them
```

- `recipient add <age1…> [--name NAME]` needs the data key. The first one
  upgrades a version 1 store to version 2 (backup first, then a verify step;
  a one-time notice says wayu 7.0 cannot read it): the master key becomes the
  data key unchanged, this machine is added as `hostname -s`, value lines are
  untouched. `--name` is required for another machine's key (default
  `hostname -s` for this machine's own; when the hostname is empty or an IP
  address there is no default: `64`, add this machine first with
  `wayu secrets recipient add "$(wayu secrets identity)" --name NAME`). It
  prints the data key's fingerprint (`data key fingerprint: …`) and, for
  another machine, the `adopt` step to run there. `65`: bad or reserved recipient
  (post-quantum `age1pq1…` is reserved, not supported), bad name, duplicate
  name or recipient. `64`: missing `--name` for another machine.
- `recipient rm <NAME> --yes` drops the machine and always rotates: a new
  data key, every value re-encrypted, re-wrapped to the remaining recipients,
  a rotation proof appended, the session cache and backup copies of
  `secrets.json` dropped. The removed machine can no longer read values
  stored from then on (it already decrypted the old ones: rotate those
  credentials upstream). Machines that have not synced since the `rm` are
  exposed until they do: the removed machine still holds the old key and
  can sign a rotation from it, which such a machine accepts. The recovery
  passphrase survives `rm`: if the removed machine knew it, replace it
  (`recovery rm --yes`, then `recovery add`; `rm` says so). Removing this
  machine or the last recipient is refused (`65`). Without `--yes`: `64`.
  An entry that fails the stanza check is dropped before the check runs on
  the rest, so the `rm` an error names always works.
- `recipient rename <OLD> <NEW>`, `recipient list [--json]` (marks this
  machine; also prints the data key's fingerprint).
- `rekey` on a version 2 store makes a new data key, wraps it to every
  recipient and appends a rotation proof.
- Each machine caches the data key it verified in the backend's existing
  master-key item, with what it verified (local state: that it read
  version 2, the recipients, the ones it saw removed, the keys it
  replaced). Shell start uses it while its fingerprint (`key_id`) matches:
  no public-key operation, no extra fork. A different key is taken from
  this machine's stanza only when the rotation proofs (at most 16) chain it
  to the cached key and it lists no machine this one saw removed; stderr
  prints `adopted data key … (rotation from … verified); recipients: +x,
  -y`. A machine with nothing cached (a new one) takes no key by itself: it
  exits `78` naming `wayu secrets adopt --yes`, which prints the
  fingerprint to compare with the one `recipient add` printed. An unproven
  key, or one listing a removed machine again, is also `78` naming `adopt`:
  compare the fingerprint with `recipient list` on another machine first.
  `adopt` exits `78` when this machine has no stanza.
- A `secrets.json` under a key this machine replaced (an old copy synced
  back) exits `78` ("older than this machine's data key"): get the current
  file again; `adopt` and `recovery unlock` refuse that key too. A version 1
  file on a machine that read version 2 (a downgrade) exits `78` for every
  read and write: sync the version 2 file again, or, going back to one
  machine on purpose, `adopt --yes` (only when every value decrypts with
  this machine's key).
- A machine that is not a recipient prints `wayu: secrets not loaded: this
  machine is not a recipient …; run 'wayu secrets identity' and add it from
  a machine that is` at shell start.
- `recovery add` sets a passphrase stanza (argon2id; wayu-only, not an age
  stanza): `recovery unlock` (passphrase on stdin) recovers the data key on
  any machine with the file, caches it, and says how to add the machine.
  `recovery rm --yes` drops it and rotates. A passphrase shorter than 12
  characters, or a wrong one (or a modified salt: "wrong passphrase, or the
  recovery entry was modified"): `65`. argon2id parameters other than the
  ones wayu writes (64 MiB, 3 passes, 4 lanes): `78`, before any work.
- Every error exits non-zero and names the command that fixes it.
  `--dry-run` writes nothing (no identity, no key, no notice marker).

### `wayu optimize`

`wayu optimize [--check] [--dry-run] [--yes]`: move the lines installers
append to your shell startup files into wayu, and remove them from the file.
Scanned, in load order, for the current shell (or `--shell`): zsh
`~/.zshenv` and `$ZDOTDIR` (else `~`) `.zshenv`, `.zprofile`, `.zshrc`,
`.zlogin`; bash `.bash_profile`, `.bash_login`, `.profile`, `.bashrc`; fish
`conf.d/*.fish`, `config.fish`. Only lines **after** the line that loads
wayu, and only top-level statements: anything inside `if`/`for`/`while`/
`case`/function bodies, here-documents, compound lines and values wayu can't
reproduce exactly stays untouched.

| Line | Becomes |
|---|---|
| `source <(tool completion zsh)`, `. <(…)`, `eval "$(tool init zsh)"`; fish `tool init fish \| source` | A cached generator (entries.json `generators`): `core.<ext>` runs `_wayu_evalcache tool …` (output cached, regenerated when the binary changes; `wayu build clean` clears it). Only from the interactive file (`.zshrc`, `.bashrc`; fish: any), only for a plain command on PATH whose arguments name an `init`, `completion(s)`, `hook`, `shellenv` or `activate` subcommand; zsh/bash run it in interactive shells only |
| `fpath=(dir $fpath)`, `fpath+=(dir)`, `FPATH=dir:$FPATH` (zsh) | entries.json `fpath` (see `wayu completions fpath`): on `fpath` before wayu's `compinit` |
| `compinit`, `autoload -Uz compinit && compinit -C …` (zsh) | Removed: wayu already runs `compinit` |
| `export PATH=dir:$PATH`, `PATH="$PATH:dir"`, `path=(dir $path)`; fish `set -gx PATH dir $PATH`, `fish_add_path dir` | PATH entries, prepends in front of the list (a later line further in front), appends at its end (a dir already listed stays where it is) |
| `alias name=value` (fish also `alias name value`) | An alias; the value must not expand when defined (`alias x="cd $HOME"` stays) |
| `export NAME=value`; fish `set -gx NAME value` | A constant; a secret-looking name or value is stored encrypted (`const add --secret`). Values may use `$HOME`, `$USER`, `~/` and constants wayu already has |

Without `--yes` it prints a unified diff per file (a secret constant's lines
show as a placeholder, never the value) and the list of what moves,
then exits `64`; `--dry-run` prints the same and exits `0`. With `--yes` each
changed file is backed up (`wayu backup restore .zshrc --yes` undoes it;
entries.json is backed up too; a moved secret stays in plaintext in that rc
backup, which wayu says and never deletes on its own), rewritten atomically, entries.json updated
under the config lock and the init files regenerated. A second run finds
nothing and exits `0`.

| Flag | |
|---|---|
| `--check` | Write nothing; list the optimizable lines and exit `1` when there are any, `0` when there are none |

Open shells notice changes: the prompt hook compares the startup files'
mtimes with `<data>/rc_check.stamp` (a builtin `-nt` test, no fork) and, when
one is newer, runs `wayu optimize --notify` once, which prints
`wayu: ~/.zshrc changed: N lines can be optimized (wayu optimize)` on stderr
(once per change). With `[settings] auto_optimize = true` in wayu.toml it moves
them instead (with backups) and prints what it moved.

### `wayu reload` (`watch`, `hot-reload`)

`wayu reload [start|stop|status|regenerate]`. `start` (the default) watches
wayu.toml, entries.json and secrets.json and regenerates the init files on
change (debounced) until interrupted (a secrets.json change, including the
file appearing or going away, also drops the secrets session cache; script
sources too: an edit rebuilds the script); `stop` stops
a running watcher; `status` says whether one runs; `regenerate` (`regen`)
regenerates once. The running watcher holds a lock on `<data>/watcher.lock`;
`stop` / `status` treat a `watcher.pid` without that lock held as stale
(removed, nothing signalled), and `start` refuses while it is held. `stop`
signals only the process holding the lock, and only when `watcher.pid`
names it (otherwise it exits `1` without signalling). The watcher rebuilds
scripts and regenerates under the config lock, like the CLI.

### `wayu version`

Prints `wayu vX.Y.Z`.

### `wayu help`

Prints the global help: commands, flags, command flags, examples, exit codes.

## JSON output

`--json` is accepted by `path|alias|const|plugin|backup|script list`,
`secrets recipient list`, `search` and `doctor` (and by any `help`); anywhere else it exits `64`. Output is one
JSON document on stdout (errors stay on stderr); an empty list is `[]`. The
shapes below are checked by `tests/integration/test_cli_output.rb` — new
keys may be added, existing ones keep their meaning.

| Command | Document |
|---------|----------|
| `path list` | `{"paths": [{"path", "source", "exists": bool}]}` |
| `alias list` | `{"aliases": [{"alias", "command", "source"}]}` |
| `const list` | `{"constants": [{"constant", "value", "source"}]}`; an encrypted constant is `{"constant", "secret": true, "source"}` (no `value`; source `wayu (secret)` or `wayu (secret, inactive)`), plus `"run_only": true` and source `wayu (run-only)` for a run-only one |
| `plugin list` | `{"plugins": [{"name", "enabled": bool, "priority": int, "shell", "url", "commit", "installed_path", "conflicts": [{"kind", "name", "with"}]}], "count": int, "enabled": int}` |
| `backup list` | `{"backups": [{"file", "count": int, "entries": [{"index": int, "timestamp", "size_bytes": int, "path", "pre_restore": bool}]}]}` |
| `script list` | `{"scripts": [{"name", "lang", "source", "bin", "compiled": bool, "stale": bool}], "count": int}` |
| `secrets recipient list` | `{"recipients": [{"name", "recipient", "this_machine": bool}], "key_id", "recovery": bool}` (experimental); a version 1 store has `"recipients": []` and `"key_id": ""` |
| `search QUERY` | `{"query", "results": [{"type", "name", "value", "match", "field", "score": int}], "count": int}`; `field` is always `name`; an encrypted constant adds `"secret": true` (its `value` is `""`) |
| `doctor` | `{"checks": [{"name", "status", "message", "fixable": bool}], "summary": {"ok", "warnings", "errors", "info", "fixable"}}` |

Unmarked fields are strings. `source` is `wayu`, `wayu (inactive)` (in
entries.json but not in this shell's environment) or `external`; `--source`
and `--full` filter rows, not the shape. `const list` masks secret-looking
values as `********` unless `--reveal` is given. Plugin `shell` is
`zsh|bash|both|fish|any`; a conflict's `kind` is `function|alias|env` and
`with` is another plugin or `entries.json`. Doctor `status` is
`ok|warning|error|info`; `backup list` `timestamp` is ISO 8601 UTC.

## Exit codes

BSD `sysexits.h` values (`EXIT_*` in `src/interfaces.odin`):

| Code | Name | Meaning |
|---|---|---|
| 0 | `EXIT_SUCCESS` | Success (also: nothing to do) |
| 1 | `EXIT_FAILURE` | General error (e.g. the editor exited non-zero; the TUI started without a terminal); `optimize --check`: lines can be optimized |
| 64 | `EXIT_USAGE` | Bad usage: unknown command, action or option; missing argument; `--json` where unsupported; missing `--yes` |
| 65 | `EXIT_DATAERR` | Bad input: invalid name or value, no such entry, unknown template, `toml validate` failed |
| 66 | `EXIT_NOINPUT` | Input file or directory not found or unreadable (`path add` of a missing dir) |
| 69 | `EXIT_UNAVAILABLE` | A required tool is not installed (`script new`: the language's interpreter or compiler) |
| 71 | `EXIT_OSERR` | TUI: the terminal could not be put in raw mode |
| 73 | `EXIT_CANTCREAT` | Cannot create an output file or directory |
| 74 | `EXIT_IOERR` | Read/write failure, failed git operation |
| 77 | `EXIT_NOPERM` | Permission denied |
| 78 | `EXIT_CONFIG` | Configuration problem: not initialized, invalid `hooks.conf`, `entries.json` or `plugins.json` (`build`), relative `WAYU_CONFIG_DIR` / `WAYU_DATA_DIR`, `doctor` found an error, `export check` found no current turbo file |
| 126 | `EXIT_EXEC_NOT_RUNNABLE` | `secrets run`: the command was found but cannot be executed |
| 127 | `EXIT_EXEC_NOT_FOUND` | `secrets run`: the command was not found |

Interrupted (`SIGINT`, `SIGTERM`, `SIGHUP`) while a child process runs (git,
a compiler, a profiled shell), wayu kills the child's whole process group,
undoes a partial `plugin add` clone and exits `128 + signal` (`130` for
Ctrl-C, `143` for `SIGTERM`, `129` for `SIGHUP`).

### Exit code examples

Run against a freshly initialized config (`wayu init`) by
`tests/integration/test_exit_codes.rb`; keep the table format
(`` | `wayu …` | code | `` ).

| Command | Exit |
|---|---|
| `wayu --version` | 0 |
| `wayu toml validate` | 0 |
| `wayu toml` | 0 |
| `wayu path list --json` | 0 |
| `wayu alias add gpf git push -f --dry-run` | 0 |
| `wayu bogus` | 64 |
| `wayu path list --dryrun` | 64 |
| `wayu path add /tmp --json` | 64 |
| `wayu path add` | 64 |
| `wayu alias check` | 64 |
| `wayu toml bogus` | 64 |
| `wayu hooks bogus` | 64 |
| `wayu config bogus` | 64 |
| `wayu doctor bogus` | 64 |
| `wayu path list --source bogus` | 64 |
| `wayu --shell bogus path list` | 64 |
| `wayu init extra` | 64 |
| `wayu init --template` | 64 |
| `wayu search` | 64 |
| `wayu plugin priority` | 64 |
| `wayu doctor --optimize` | 64 |
| `wayu doctor --fix` | 64 |
| `wayu secrets run` | 64 |
| `wayu const add NAME --run-only --json` | 64 |
| `wayu const get NO_SUCH_NAME` | 65 |
| `wayu secrets run NO_SUCH_NAME -- true` | 65 |
| `wayu path rm /no/such/dir` | 65 |
| `wayu alias add 'a b' x` | 65 |
| `wayu const add PATH /x` | 65 |
| `wayu path add /etc/hosts` | 65 |
| `wayu plugin rm no-such-plugin` | 65 |
| `wayu template apply no-such-template` | 65 |
| `wayu path add /no/such/dir` | 66 |
| `wayu completions add jj /no/such/_jj` | 66 |
| `wayu function rm no_such_function` | 66 |
| `wayu script rm no_such_script --yes` | 65 |
| `wayu script new x --lang cobol` | 64 |
| `wayu optimize --check` | 0 |
| `wayu optimize bogus` | 64 |
| `wayu completions fpath bogus` | 64 |
| `wayu completions --generate` | 64 |
| `wayu completions list -g` | 64 |
| `wayu doctor --profile --json` | 64 |
| `wayu doctor --fix --profile --yes` | 64 |
| `wayu export --eval --check` | 64 |
| `wayu path list x` | 64 |
| `wayu secrets lock x` | 64 |
| `wayu secrets adopt` | 64 |
| `wayu secrets recipient rm laptop` | 64 |
| `wayu secrets recipient bogus` | 64 |
| `wayu secrets recovery rm` | 64 |
| `wayu secrets identity --json` | 64 |
| `wayu secrets recipient add age1notakey --name x` | 65 |
| `wayu secrets recipient add age1pq1qqqqqqqqqqqqqqqq --name x` | 65 |
| `wayu build --test` | 64 |
| `wayu build --snapshot` | 64 |
| `wayu build --full` | 64 |
| `wayu plugin search -c=dev` | 64 |
| `wayu export check` | 78 |

Also tested: `path`, `alias` and `const` exit `78` before `wayu init`;
`wayu doctor` exits `78` and `wayu toml validate` `65` when wayu.toml does
not parse; every command that reads entries.json exits `78` when it does not
parse.

## Environment variables

| Variable | Effect |
|---|---|
| `WAYU_CONFIG_DIR` | Config dir (wayu.toml, extra/tools, hooks.conf); default `~/.config/wayu`. Must be absolute (else exit `78`) |
| `WAYU_DATA_DIR` | Data dir (entries.json, functions/, scripts/, bin/, plugins, generated init files, completions, backups); default `${XDG_DATA_HOME:-~/.local/share}/wayu`. Must be absolute (else exit `78`) |
| `XDG_DATA_HOME` | Base of the default data dir (ignored when relative) |
| `SHELL` | Shell detection (override with `--shell`) |
| `NO_COLOR` | Disable colors (wins over `FORCE_COLOR`) |
| `FORCE_COLOR`, `CLICOLOR_FORCE` | Keep colors when stdout is not a terminal |
| `VISUAL`, `EDITOR` | Editor for `config edit|extend`, `hooks edit`, `function add`, `script new|edit` (may carry arguments, e.g. `code --wait`); default `vi` |
| `COLUMNS` | Table width when not writing to a terminal |
| `XDG_CACHE_HOME` | Base of the `[tools]` evalcache |
| `WAYU_GIT_TIMEOUT` | Seconds before a plugin clone/fetch/check is killed |
| `WAYU_THEME` | TUI: `light` or `dark` (skips background detection) |
| `ESCDELAY` | TUI: milliseconds that separate `Esc` from an Alt+key chord (default 100) |
