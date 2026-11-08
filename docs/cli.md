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
| `--full`, `-f` | List views: include external entries (same as `--source all`) |
| `--source <filter>`, `--source=<filter>` | List views: `wayu` (default), `inactive`, `external` or `all` |
| `--tui` | Open the TUI (same as running `wayu` with no arguments) |
| `--help`, `-h`, `help` | Global help, or a command's help after the command (`wayu path --help`) |
| `--version`, `-v`, `version` | Print `wayu vX.Y.Z` |
| `--` | End of flags: every later word is a literal argument |

`--yes` is required by `path clean`, `path dedup`, `backup restore`,
`backup remove`, `plugin remove`, `function remove` and `config scan --fix`
whenever they would change something, and always by `doctor --fix` (unless
`--dry-run`); without it they print what would happen and exit `64`.

Developer flags (golden-file tests, see AGENTS.md): `-c=<component>`,
`--test`, `--snapshot`.

## Where flags are recognised

1. `--` ends flag parsing. Everything after it is a literal argument and
   the `--` itself is dropped: `wayu alias add g -- -n` stores `-n`.
2. In `alias add` and `constants add` (`const`, `env`), once the name and the
   first value word have been given, the rest of the line is the value,
   dashes included: `wayu alias add gpf git push -f` stores `git push -f`.
   Flags may still come before the first value word
   (`wayu alias add -n gc 'git commit'`). A dash word right where the value
   starts is the value: `wayu const add OFFSET -5`.
   Exception: `--dry-run`, `--yes`, `--json` and `--no-color` at the very
   end of the line are flags (`wayu alias add gpf git push -f --dry-run`
   previews). To keep them in the value, put `--` before it:
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

Manage `[paths]` in wayu.toml. Default action: `list`.

| Action | Arguments | |
|---|---|---|
| `add` | `<dir>` or `<key>=<dir>` | Add a directory (must exist, else exit `66`; `~` and relative paths are resolved). The key defaults to the directory's base name; an existing directory is left as is (exit `0`) |
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

Manage `[aliases]`. Default action: `list`. Names: ASCII letters, digits,
`_`, and `-` after the first character.

| Action | Arguments | |
|---|---|---|
| `add` | `<name> <command...>` | Add or replace an alias |
| `remove`, `rm` | `<name>` | |
| `list`, `ls` | | `--json`, `--full`, `--source` |
| `get` | `<name>` | Print the alias's command |
| `help` | | |

### `wayu constants` (`const`, `env`)

Manage `[env]`. Default action: `list`.

| Action | Arguments | |
|---|---|---|
| `add` | `<NAME> <value...>` | Add or replace a variable |
| `remove`, `rm` | `<NAME>` | |
| `list`, `ls` | | `--json`, `--full`, `--source`, `--reveal` |
| `get` | `<NAME>` | Print the real value (exact name only) |
| `help` | | |

| Flag | |
|---|---|
| `--reveal` | `list`: show secret-looking values instead of `********` |

`get` is safe in scripts: `X=$(wayu const get NAME)` either gets that
variable's value or fails with exit `65`.

### `wayu search` (`find`, `f`)

`wayu search <query>`: fuzzy search over PATH entries, alias names and
constant names (never values). Match types: exact, prefix, substring,
acronym (`frwrks` → `FIREWORKS_AI_API_KEY`), fuzzy. Supports `--json`.
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
| `help` | | |

### `wayu backup`

Default action: `list`. wayu backs a file up before changing it (once per
command) and keeps the newest 5 per file in `backup/`.

| Action | Arguments | |
|---|---|---|
| `list`, `ls` | `[type]` | All backup groups (wayu.toml, plugins.json, the rc file, …); `--json` |
| `restore` | `<type> [N\|file]` | Restore wayu.toml from the newest backup, backup #N, or a file (`--yes`) |
| `remove`, `rm` | `[type]` | Prune to the newest 5 (`--yes`) |
| `help` | | |

`type` is `path`, `alias`, `constants` or `toml`; all name wayu.toml, so a
restore reverts the whole file. The current file is backed up first.

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

`wayu init [--template <name>]`: create the config and data dirs, a
`wayu.toml` scaffold and `init.<ext>`, generate the init files, and offer to
add `source …/init.<ext>` to your rc file (only when stdin is a terminal;
otherwise it prints the line). Safe to re-run: existing files are kept and an
unmodified old `init.<ext>` is updated. `--shell` picks the shell.

| Flag | |
|---|---|
| `--template <name>`, `--template=<name>` | Then apply a template (see `wayu template list`) |

### `wayu migrate`

| Usage | |
|---|---|
| `wayu migrate` | Import legacy `path` / `aliases` / `constants.<ext>` into wayu.toml (all or nothing) |
| `wayu migrate --schema` | Rewrite an obsolete `[[paths]]` / `[[aliases]]` / `[[constants]]` wayu.toml as tables |
| `wayu migrate --from <shell> --to <shell>` | Switch `[shell] type` and generate the target shell's files |

| Flag | |
|---|---|
| `--from`, `--to` | Source and target shell (`zsh`, `bash`, `fish`); both required |
| `--schema` | Schema upgrade |

### `wayu config`

Without an action it prints its help.

| Action | |
|---|---|
| `edit` | Open wayu.toml in `$VISUAL` / `$EDITOR` (else `vi`), then regenerate |
| `extend` | Open `extra.<ext>` (shell code sourced at the end of init) |
| `scan` | Find tool-init blocks in your rc file that could move to `extra.<ext>` |
| `help` | |

| Flag | |
|---|---|
| `--fix` | `scan`: append the blocks found to `extra.<ext>` (`--yes`) |

### `wayu build`

| Action | |
|---|---|
| *(none)* | Regenerate the init files from wayu.toml (after a hand edit) |
| `eval` | Regenerate, then print `source <data-dir>/core.<ext>` |
| `turbo` | Same as `wayu export --turbo` |
| `profile` | Time shell startup and each section, tool and plugin of `core.<ext>` |
| `clean` | Delete the `[tools]` evalcache (`${XDG_CACHE_HOME:-~/.cache}/wayu/evalcache`) |
| `help` | |

### `wayu export`

Default action: `turbo`. Each action may also be written as a flag
(`--turbo`, `--eval`, `--check`).

| Action | |
|---|---|
| `turbo` | Write `turbo.<ext>`, a copy of `core.<ext>` (zsh, bash) |
| `eval` | Print `[env]`, `[paths]` and `[aliases]` as shell code for `eval` (writes nothing) |
| `check` | Exit `0` if `turbo.<ext>` is current, `78` if it is missing or stale |
| `list`, `ls` | Show the formats |
| `help` | |

### `wayu toml`

| Action | |
|---|---|
| `validate` | Strict check of wayu.toml (syntax, duplicate keys, names, `[shell] type`); exit `65` on error |
| `show` | Print wayu.toml with secret-looking `[env]` values masked |
| `keys` | List the top-level keys |
| `convert` | Same as `wayu migrate` |
| `help` | |

| Flag | |
|---|---|
| `--reveal` | `show`: print the file verbatim |

Without an action, `wayu toml` behaves like `wayu toml keys`.

### `wayu doctor`

Health checks: installation, rc file, PATH entries, plugins and plugin
conflicts, backups, wayu.toml, turbo file, dependencies. Exits `78` when any
check reports an error (warnings don't), so it can gate CI. Supports `--json`.

| Flag | |
|---|---|
| `--fix` | Remove missing / duplicate `[paths]` entries (`--yes`, or `--dry-run` to preview) |
| `--profile` | Same as `wayu build profile` |
| `--optimize` | Removed; prints a pointer to `wayu build` / `wayu export` and exits `64` |

### `wayu template`

Default action: `list`. Templates: `developer`, `minimal`, `data-science`,
`full`.

| Action | Arguments | |
|---|---|---|
| `list`, `ls` | | |
| `apply` | `<name>` | Add the template's entries; existing ones are kept |
| `help` | | |

### `wayu hooks`

Default action: `list`. Hooks are configured in `hooks.conf`
([config-reference.md](config-reference.md)).

| Action | |
|---|---|
| `list`, `ls` | Show configured hooks |
| `edit` | Open `hooks.conf` in the editor |
| `help` | |

### `wayu function` (`functions`, `func`, `fn`)

Shell functions as files in the config dir's `functions/`. Default action:
`list`.

| Action | Arguments | |
|---|---|---|
| `add`, `new`, `edit` | `<name>` | Create (from a skeleton for the shell) or open the function file in the editor |
| `list`, `ls` | | |
| `remove`, `rm`, `delete` | `<name>` | Delete the file (`--yes`) |
| `help` | | |

### `wayu reload` (`watch`, `hot-reload`)

`wayu reload [start|stop|status|regenerate]`. `start` (the default) watches
wayu.toml and regenerates the init files on change (debounced) until
interrupted; `stop` stops a running watcher; `regenerate` (`regen`)
regenerates once.

### `wayu version`

Prints `wayu vX.Y.Z`.

### `wayu help`

Prints the global help: commands, flags, command flags, examples, exit codes.

## JSON output

`--json` is accepted by `path|alias|const|plugin|backup list`, `search` and
`doctor` (and by any `help`); anywhere else it exits `64`. Output is one
JSON document on stdout (errors stay on stderr); an empty list is `[]`. The
shapes below are checked by `tests/integration/test_cli_output.rb` — new
keys may be added, existing ones keep their meaning.

| Command | Document |
|---------|----------|
| `path list` | `{"paths": [{"path", "source", "exists": bool}]}` |
| `alias list` | `{"aliases": [{"alias", "command", "source"}]}` |
| `const list` | `{"constants": [{"constant", "value", "source"}]}` |
| `plugin list` | `{"plugins": [{"name", "enabled": bool, "priority": int, "shell", "url", "commit", "installed_path", "conflicts": [{"kind", "name", "with"}]}], "count": int, "enabled": int}` |
| `backup list` | `{"backups": [{"file", "count": int, "entries": [{"index": int, "timestamp", "size_bytes": int, "path", "pre_restore": bool}]}]}` |
| `search QUERY` | `{"query", "results": [{"type", "name", "value", "match", "field", "score": int}], "count": int}` |
| `doctor` | `{"checks": [{"name", "status", "message", "fixable": bool}], "summary": {"ok", "warnings", "errors", "info", "fixable"}}` |

Unmarked fields are strings. `source` is `wayu`, `wayu (inactive)` (in
wayu.toml but not in this shell's environment) or `external`; `--source`
and `--full` filter rows, not the shape. `const list` masks secret-looking
values as `********` unless `--reveal` is given. Plugin `shell` is
`zsh|bash|both|fish|any`; a conflict's `kind` is `function|alias|env` and
`with` is another plugin or `wayu.toml`. Doctor `status` is
`ok|warning|error|info`; `backup list` `timestamp` is ISO 8601 UTC.

## Exit codes

BSD `sysexits.h` values (`EXIT_*` in `src/interfaces.odin`):

| Code | Name | Meaning |
|---|---|---|
| 0 | `EXIT_SUCCESS` | Success (also: nothing to do) |
| 1 | `EXIT_FAILURE` | General error (e.g. the editor exited non-zero; the TUI started without a terminal) |
| 64 | `EXIT_USAGE` | Bad usage: unknown command, action or option; missing argument; `--json` where unsupported; missing `--yes` |
| 65 | `EXIT_DATAERR` | Bad input: invalid name or value, no such entry, unknown template, `toml validate` failed |
| 66 | `EXIT_NOINPUT` | Input file or directory not found or unreadable (`path add` of a missing dir) |
| 71 | `EXIT_OSERR` | TUI: the terminal could not be put in raw mode |
| 73 | `EXIT_CANTCREAT` | Cannot create an output file or directory |
| 74 | `EXIT_IOERR` | Read/write failure, failed git operation |
| 77 | `EXIT_NOPERM` | Permission denied |
| 78 | `EXIT_CONFIG` | Configuration problem: not initialized, obsolete wayu.toml schema, invalid `hooks.conf`, `doctor` found an error, `export check` found no current turbo file |

### Exit code examples

Run against a freshly initialized config (`wayu init`) by
`tests/integration/test_exit_codes.rb`; keep the table format
(`` | `wayu …` | code | `` ).

| Command | Exit |
|---|---|
| `wayu --version` | 0 |
| `wayu toml validate` | 0 |
| `wayu path list --json` | 0 |
| `wayu alias add gpf git push -f --dry-run` | 0 |
| `wayu bogus` | 64 |
| `wayu path list --dryrun` | 64 |
| `wayu path add /tmp --json` | 64 |
| `wayu alias check` | 64 |
| `wayu init extra` | 64 |
| `wayu init --template` | 64 |
| `wayu search` | 64 |
| `wayu plugin priority` | 64 |
| `wayu doctor --optimize` | 64 |
| `wayu migrate --from zsh` | 64 |
| `wayu doctor --fix` | 64 |
| `wayu const get NO_SUCH_NAME` | 65 |
| `wayu path rm /no/such/dir` | 65 |
| `wayu alias add 'a b' x` | 65 |
| `wayu plugin rm no-such-plugin` | 65 |
| `wayu template apply no-such-template` | 65 |
| `wayu path add /no/such/dir` | 66 |
| `wayu completions add jj /no/such/_jj` | 66 |
| `wayu function rm no_such_function` | 66 |
| `wayu export check` | 78 |

Also tested: `path`, `alias` and `const` exit `78` before `wayu init`;
`wayu doctor` exits `78` and `wayu toml validate` `65` when wayu.toml does
not parse.

## Environment variables

| Variable | Effect |
|---|---|
| `WAYU_CONFIG_DIR` | Config dir (wayu.toml, extra/tools, hooks.conf, functions/); default `~/.config/wayu` |
| `WAYU_DATA_DIR` | Data dir (generated init files, plugins, completions, backups); default: the config dir |
| `SHELL` | Shell detection (override with `--shell`) |
| `NO_COLOR` | Disable colors (wins over `FORCE_COLOR`) |
| `FORCE_COLOR`, `CLICOLOR_FORCE` | Keep colors when stdout is not a terminal |
| `VISUAL`, `EDITOR` | Editor for `config edit|extend`, `hooks edit`, `function add` (may carry arguments, e.g. `code --wait`); default `vi` |
| `COLUMNS` | Table width when not writing to a terminal |
| `XDG_CACHE_HOME` | Base of the `[tools]` evalcache |
| `WAYU_GIT_TIMEOUT` | Seconds before a plugin clone/fetch/check is killed |
| `WAYU_THEME` | TUI: `light` or `dark` (skips background detection) |
| `ESCDELAY` | TUI: milliseconds that separate `Esc` from an Alt+key chord (default 100) |
