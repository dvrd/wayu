# Changelog

All notable changes to wayu will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Behavior changes per release: [docs/UPGRADING.md](docs/UPGRADING.md).

## [6.0.0] - 2026-11-09

### ⚠ Upgrade notes

- **plugin**: `plugin update` fails (exit 74) instead of resetting a checkout whose HEAD has commits not on the remote. `plugins.json` `dependencies` entries must be valid plugin names, otherwise commands reading it exit 78.
- **path**: Path clean keeps [paths] entries whose $VAR is set in
neither wayu.toml [env] nor the environment, and resolves [env] variables
(dedup too). clean/dedup exit 78 without changes on a duplicate [paths]
key. pre/post_path_remove get the directory as {path} when removing by key.
- **tui**: In the TUI with --dry-run, add/remove notifications read
"Dry run: would add/remove …" instead of "Added/Removed …", and the
dry-run preview is no longer printed over the TUI.
- **shell**: [env] values: `$1`, `$$`, `$?`, a trailing `$`, an
unclosed `${` and zsh flags like `${(e)...}` are now literal text; in zsh
- **doctor**: `wayu doctor` no longer reports relative [paths]
entries as missing and `doctor --fix` keeps them; the PATH check note
now reads "N use(s) unset variables or relative paths (left alone)".
- **migrate,backup**: `wayu migrate --schema` exits 65 and writes nothing
when a rewritten section holds a value it can't convert exactly
(multi-line strings, arrays, inline tables); it lists them as
- **doctor**: `wayu doctor --fix` exits 78 without writing when
wayu.toml [paths] repeats a key it would drop; remove or rename the
repeated key by hand.
- **hooks**: Hooks.conf commands with a placeholder inside double
quotes are refused (exit 78, nothing written). Write the placeholder
unquoted, inside '...' for an inner shell, or use "$WAYU_HOOK_PATH" /
"$WAYU_HOOK_NAME" / "$WAYU_HOOK_VALUE".
- **const**: `wayu const list` (including --full and --json) and
`wayu toml show` show secret-looking values as `********`. Pass
--reveal for real values, or use `wayu const get NAME`. The TUI
constants view masks them until `v` is pressed.
- **plugin**: `wayu plugin update|enable|disable|priority|get|rm NAME`
require the exact plugin name. A miss prints nothing on stdout, lists up
to 5 similar plugin names on stderr and exits 65; it never acts on a
fuzzy guess or prompts. `plugin rm` of an unknown name exits 65 (it used
to exit 0 "already removed" when nothing was similar).
- **plugin**: Plugin add exits 65 and installs nothing when the repo
has nothing to load (use --use); extra plugin add arguments exit 64. URL
adds record detected shells. Generated plugins.<ext> sources only the
first entry file and picks up .zsh-theme/.sh entries. 22 registry keys
removed; pure-fish installs as pure-fish. Network git: batch-mode ssh
(prompts fail), stalled https aborts, git killed after 10 min / 60 s
(WAYU_GIT_TIMEOUT). See docs/UPGRADING.md "Unreleased".
- **build**: ./build_it install installs to ~/.local/bin ($PREFIX/bin), not /usr/local/bin, and refuses while Homebrew manages wayu unless --force.
- **zsh**: Zsh writes ${ZDOTDIR:-$HOME}/.zcompdump.wayu next to
.zcompdump (the completions listing at the last dump rebuild); the first
shell after upgrading rebuilds the dump once.
- **env**: In [env] values, ${NAME<op>} with an operator other than
- = + ? (optionally prefixed by :), # % / is now literal text in zsh/bash
(e.g. ${X@P}, ${X[1]}, ${X:1}, ${X^}, zsh ${HOME:h}); ${#NAME} only
expands without an operator. fish: $NAME before a non-ASCII letter now
expands NAME.
- **doctor**: Wayu doctor (bash) prints a new 'bash PROMPT_COMMAND'
warning, also in --json, when a startup file replaces PROMPT_COMMAND
after loading wayu. Exit status is unchanged.
- **toml**: Toml validate/doctor/backup restore accept BOMs,
multi-line arrays, quoted and dotted keys, floats and dates, and reject
duplicate keys/tables; parse errors name the line. Quoted keys are decoded
in every list ("q\"k" is the alias q"k; alias rm .. finds ".."). TUI shows
[paths] in file order and shows entries of files with syntax errors.
Arrays/inline tables in [paths]/[aliases]/[env] are skipped instead of
exported as raw text; integers are read as their value. wayu writes keys
needing quotes quoted and control characters escaped. migrate --schema
lists invalid TOML lines instead of copying them. See docs/UPGRADING.md.
- **init**: WAYU_DATA_DIR is honoured together with WAYU_CONFIG_DIR;
init.<ext> loads the files next to itself instead of ~/.config/wayu; core
exports WAYU_CONFIG_DIR / WAYU_DATA_DIR when they are not the defaults.
- **tools**: Evalcache files gain a signature header (old caches are
rebuilt once), tools are run with `command`, and `wayu build clean` is a
new build target.
- **tools**: [tools] args with a newline, ; & | < > ( ), $(...),
backticks or * ? [ are refused (`wayu build` exits 78); {a,b} is no longer
brace-expanded.
- **prompt**: The default native prompt gains separators and hides the
user name outside SSH/root; the prompt toggle is opt-in and bound in
explicit keymaps.
- **zsh**: Every wayu write now spawns a background zcompile of the
regenerated zsh files.
- **cli**: Piped or redirected output is plain text (no ANSI codes)
unless FORCE_COLOR=1 / CLICOLOR_FORCE=1; NO_COLOR=1 and --no-color now
remove every escape code, including tables, errors, doctor and help.
- **cli**: ERROR/warning lines moved from stdout to stderr; path
commands on an uninitialized config exit 78 instead of 66.
- **cli**: List commands print JSON (not an info line) for empty
lists under --json; path list --json --source external/--full now
includes external entries; search honors --json.
- **cli**: An action word a command does not have (alias check,
backup clean, path enable, ...) exits 64 with the command's help instead
of doing nothing or exiting 1; --json where no JSON output exists exits
64 instead of being ignored.
- **toml**: New wayu.toml files (wayu init, config edit, any command
creating a missing wayu.toml) and `migrate --from X --to Y` write
`[shell] type = "zsh"|"bash"|"fish"` in lowercase. `wayu toml validate`
now rejects a `[shell] type` other than zsh/bash/fish (any case), e.g. the
"Unknown" older versions wrote when no shell was detected (exit 65).
- **migrate**: `wayu migrate` on an install without wayu.toml now
writes `[shell] type = "<shell>"`, `[aliases]` and `[env]` before the
imported entries instead of a "# wayu configuration (auto-generated by
migrate)" comment line.
- **doctor**: Doctor output changes: Sync status reports PATH entries
missing from the current $PATH (INFO); a missing backup dir is INFO; the
shell dependency follows the configured shell; rc lines that only mention
the init file no longer count as loading wayu.
- **backup**: Backup list shows times with a UTC suffix and --json
timestamps are ISO-8601 (2026-11-07T14:35:37Z); backup list/rm include
non-wayu.toml backups; rc backups outside $HOME's top level are named by
path (.config%zsh%.zshrc.backup.*); restore indexes must be decimal.
- **cli**: Piped/redirected list tables are no longer truncated to
80 columns with '…'; export COLUMNS to fit a width.
- **picker**: In the interactive picker a lone Esc now cancels, and
unknown escape sequences no longer add characters to the filter.
- **editor**: A failing or missing editor now exits 1 instead of 0;
$EDITOR with arguments works; the no-EDITOR fallback is vi (was nvim for
function/config). config scan --fix no longer re-appends blocks already
in extra.<ext> and aborts with 74 when the backup fails.
- **migrate**: Migrate --schema prints a warning block on stderr when
legacy entries carry fields (description, export, secret, ...) that are
not migrated.
- **template**: Template apply no longer overwrites existing aliases,
constants or constants set in the environment; --dry-run no longer claims
the template was applied; the developer template no longer defines
alias code; init accepts --template and rejects other arguments (64).
- **backup**: `wayu backup` works while wayu.toml uses the obsolete
[[paths]] schema; `backup restore` refuses (exit 74) a wayu.toml backup
that uses the obsolete schema — copy it by hand and run
`wayu migrate --schema`.
- **init**: An unmodified init.zsh written by wayu 3.9 or older is
now replaced by the current template (old file backed up) instead of
being kept with a "has local edits" warning.
- **tui**: TUI add/delete is refused while wayu.toml uses the
obsolete [[paths]] schema instead of writing a mixed-schema file.
- **tui**: The TUI Backups view lists wayu.toml backups and
Settings counts them.
- **tui**: TUI keys and messages changed: registry Enter shows
details (install is i + confirm), plugin d no longer disables (space/x do),
dry-run notifications read "[dry-run] would ...", PATH add refuses missing
or unresolvable paths and treats name=path as a key, adding an existing
alias/constant asks to replace, Backups Enter restores and c asks first.
See docs/UPGRADING.md.
- **completions**: Regenerated completion scripts call
`wayu completions names <kind>` at TAB time; fish no longer offers action
words after the action. Re-run `wayu completions generate`.

OKAMI-181, OKAMI-182
- **plugin**: Plugin add/enable/list print conflict warnings on
stderr, plugin list --json rows gain a "conflicts" array, and doctor
may add a "plugin conflicts" warning.

OKAMI-276
- **build**: Build profile breakdown rows changed: one per tool and
plugin, lazy sections prefixed 'lazy › ', empty rows omitted; bash gets a
breakdown (or a note on bash < 5).

OKAMI-180
- **tui**: Text-style symbols such as ➜ ✔ ★ ❤ ⛰ count as one column
and combining accents/VS16/ZWJ as none, in the TUI and in CLI tables, so
such rows line up differently; the TUI draws ❤️ as ❤ and a ZWJ family emoji
as its separate emoji.
- **tui**: In the TUI, Esc followed by a key within 100ms is Alt+key
and does nothing (it was Escape then the key); a lone Esc takes effect after
100ms (ESCDELAY changes it). A paste only types into the focused text field
and is ignored elsewhere; keys typed ahead of a delete confirmation or after
a submitted form are discarded.
- **tui**: TUI list text is drawn in the terminal's default color
instead of #D0D0D0; light backgrounds (WAYU_THEME=light, COLORFGBG or the
terminal's OSC 11 answer; WAYU_THEME=dark skips the query) get darker
dividers and accents; 16-color terminals show the accent as bright magenta
and dividers as gray.
- **prompt**: The native prompt no longer switches zsh to the vi keymap
or sets KEYTIMEOUT. vi users must add `vi_mode = true` under [prompt].
KEYTIMEOUT is no longer exported. zle-line-init / zle-keymap-select
defined before wayu are now kept and run first instead of being replaced.
- **init**: Lazy.<ext>, login.<ext> and helpers.<ext> are no longer
generated (and are deleted); their content is in core.<ext>. zsh runs
compinit only in interactive shells. turbo.<ext> now equals core.<ext>
and is refreshed on every regeneration; `wayu export --turbo` output and
the `export --eval` PATH statement changed; `wayu build` no longer prints
the turbo report.
- **fish**: Fish: [paths] dirs already on PATH now move to wayu's
position; [aliases] are defined after plugins/tools; init.fish sources
tools.fish before extra.fish; [tools] entries now run in fish (zsh/bash
args retargeted to fish). See docs/UPGRADING.md "fish (core.fish)".
- **alias**: `wayu alias add`, `toml validate` and the TUI accept alias
names such as `onlead-logs`. A leading `-` is still refused.
- **init**: Generated core.zsh changes (the background .zcompdump
compile checks the dump before installing the .zwc); run `wayu build`.
- **cli**: `wayu toml` validates instead of printing keys; `toml
keys` prints the file's real keys; unknown actions of toml, hooks,
config, template, function and extra doctor arguments exit 64 (were 0);
invalid --source/--shell values exit 64; alias/const usage errors say
`wayu alias` / `wayu const`.
- **migrate**: `wayu migrate` and `wayu toml convert` are removed (exit
64). Use `wayu --shell <shell> init` to set up another shell. `wayu build`
without wayu.toml exits 78.
- **toml**: A wayu.toml on the 3.x [[paths]]/[[aliases]]/[[constants]]
schema is no longer detected: no exit 78 with a migration hint, no
backup-restore refusal, no doctor error. It is just an invalid config.
- **init**: Path/aliases/constants.<ext> are neither created nor read.
init.<ext> sources only core.<ext> (unmodified copies are refreshed on the
next regeneration).
- **init**: An untouched init.<ext> from a release older than the
previous one is no longer refreshed (it is treated as user-edited: kept,
with a warning); move it aside and run `wayu init`. Leftover lazy, login
and helpers.<ext> files are no longer deleted.
- **plugin**: Plugins.conf is ignored (no migration to plugins.json).
A plugins.json with numeric enum values ("shell": 0) fails to load (exit
78); write the names ("zsh", "source", ...).
- **backup**: Backups named in an older format no longer show in
`backup list` and cannot be restored or pruned by wayu; an existing
group/world-readable backup dir is no longer tightened (new backups are
still 0600 in a 0700 dir).
- **toml**: `toml validate` exits 65 for [[paths]]/[[aliases]]/
[[env]] (and other known tables written as arrays or values) and prints
warnings for keys wayu ignores; `doctor` warns about them.
- Functions/ files must be named <name>.zsh / <name>.bash
(as `wayu function add` writes them); others are not sourced. Functions
still under ~/.local/share/wayu/functions are not copied anymore. A
top-level `shell = "..."` in wayu.toml is not read; use [shell] type.
- **init**: `wayu build eval` exits 64; use
`source "${WAYU_DATA_DIR:-$HOME/.config/wayu}/init.zsh"` instead. zsh
reorders PATH once at the first prompt (wayu dirs before system dirs).
- **prompt**: With [prompt] enabled = true, a PROMPT/PS1 assigned
after wayu loads (e.g. in .zshrc) is replaced at the first prompt; set
[prompt] enabled = false to manage the prompt yourself.
- [paths], [aliases] and [env] are no longer read from
wayu.toml; they live in <data>/entries.json and are not converted (re-add
them with wayu path|alias|const add). The default data dir is now
- **script**: Functions/ is read from and written to the data dir
($WAYU_DATA_DIR/functions, default ~/.local/share/wayu/functions) instead
of the config dir; move existing files by hand. <data>/bin is prepended to
PATH once it holds a script. New exit code 69 for `script new` when the
interpreter/compiler is missing.
- **secrets**: A trailing `--secret` on `wayu const add` is now a flag
(encrypt the value), not part of the value; put `--` before the value to
store it literally. `--secret` elsewhere exits 64. A plain `const add` of
a secret's name exits 65. `const list --json` rows for secrets have
- **secrets**: `wayu secrets list` prints a mode column (`session` /
`run-only`) after each name; the doctor secrets message changed; a
trailing `--run-only` on `const add` is now a flag, not part of the
value. New exit codes 126/127 for `wayu secrets run`.
- **secrets**: `wayu const add NAME --secret` over a plain constant
deletes the entries.json backups that hold its plaintext value.

### Added

- **doctor**: Warn when a bash rc replaces PROMPT_COMMAND after wayu
- **completions**: Complete existing entries in zsh, bash and fish
- **plugin**: Report plugin conflicts on add/enable, list and doctor
- **build**: Profile startup per [tools] entry and per plugin
- **tui**: Suspend/resume; restore the terminal on os.exit, replay stderr
- **fish**: [tools], functions/, live PATH sync and -gpm PATH order
- **toml**: Warn on keys wayu does not read; drop dead keys
- Move PATH entries, aliases and constants to entries.json
- **script**: Wayu script for standalone scripts; functions move to data dir
- **secrets**: Encrypted constants with const add --secret
- **secrets**: Run-only secrets and wayu secrets run

### Changed

- **cli**: Drive dispatch, flags, --json and help from WAYU_COMMAND_SPECS
- **config**: Delete legacy shell-file CRUD and unused spec fields
- Delete procs, types and constants with no callers
- Delete uncalled procs in fuzzy, lock, templates and TUI code
- **prompt**: Split parse_full_prompt_config
- **migrate**: Split migrate_legacy_to_toml into phases
- **core**: Shared add checks, entry outcomes, cancellable children
- **init**: One fast generated init with every feature; thin turbo
- **search**: Drop dead fuzzy-search code; fix acronym docs
- **lock**: Remove unused wayu.lock reader
- **migrate**: Remove wayu migrate and toml convert
- **toml**: Drop obsolete [[paths]] schema detection
- **init**: Drop legacy path/aliases/constants shell files
- **init**: Keep only current/previous init template hashes
- **plugin**: Drop plugins.conf migration and numeric enums
- **backup**: Accept only the current backup name format
- Drop the remaining back-compat fallbacks

### Fixed

- **plugin**: Keep local commits on update, validate dependency names
- **path**: Clean/dedup resolve [env] vars and never drop unset ones
- **tui**: Keep the box's right border on list and table rows
- **tui**: List each environment variable once in the constants view
- **const**: List each environment variable once in const list --full
- **tui**: Dry run doesn't draw over the screen or claim success
- **shell**: Literal non-variable $ in [env]; per-shell functions/
- **alias**: Parse fish's alias listing in --full cross-reference
- **doctor**: Leave relative [paths] entries alone
- **migrate,backup**: No silent loss in migrate --schema; lock restore
- **doctor**: Refuse --fix when a dropped [paths] key is repeated
- **hooks**: Refuse placeholders inside double quotes
- **const**: Mask secret values in list views, add --reveal
- **plugin**: Plugin name lookups are exact, misses only suggest
- **tui**: Declare ioctl variadic so TIOCGWINSZ gets a valid pointer
- **plugin**: Refuse plugins with nothing to load; network git deadlines
- **build**: Install to ~/.local/bin, refuse over Homebrew
- **zsh**: Rebuild compdump when completions change within the same second
- **env**: Keep evaluating ${NAME<op>} forms literal; fuzz shell quoting
- **build**: Show unit-test output and failure names
- **plugin**: Free fish conf.d/functions match slices in the loader
- **toml**: One TOML parser behind every wayu.toml reader
- **doctor**: Malformed-toml hint names the real command (wayu toml validate)
- **init**: WAYU_CONFIG_DIR / WAYU_DATA_DIR overrides produce a working init
- **tools**: Evalcache keyed on binary identity, add `wayu build clean`
- **tools**: Quote [tools] evalcache args, refuse code-running values
- **prompt**: Toggle keymap, starship-like defaults, no bare git/awk/sed
- **zsh**: Keep zcompile bytecode fresh after edits; quote profile path
- **cli**: Honor NO_COLOR/--no-color everywhere; plain output off-TTY
- **cli**: Errors to stderr, one error per failure, help without config
- **cli**: Valid --json for empty lists, plugins, external paths, search
- Use-after-free in completions list; env leak in const list --full
- **build**: Restore core:log import needed by -debug builds
- **toml**: One wayu.toml scaffold with a lowercase [shell] type
- **migrate**: Start a new wayu.toml from the shared scaffold
- **doctor**: Honest sync status, tighter loader match, fewer false positives
- **backup**: Manage every backup group, label UTC, prune on restore
- **cli**: Don't fit list tables to 80 columns when piped
- **picker**: Decode every byte of a read; lone Esc cancels; restore on INT/QUIT
- **editor**: One launch_editor: multi-word $EDITOR, exit status checked
- **cli**: Growing temp arena; no pointer into main's stack frame
- **lock**: Drop and free nameless [[entries]] instead of leaking them
- **migrate**: List [[...]] fields --schema can't migrate
- **template**: Keep existing entries, honor --dry-run, implement init --template
- **backup**: Usable on obsolete schema; refuse obsolete-schema restore
- **init**: Recognise init.zsh templates from wayu <= 3.9
- **tui**: Refuse edits to an obsolete-schema wayu.toml
- **tui**: List and count wayu.toml backups
- **tui**: CLI add semantics, dry-run previews, reload, real hooks/settings views
- **tui**: Terminal-accurate rune widths for combining marks, VS16, ZWJ
- **tui**: Bracketed paste, Alt chords and a slow-link-safe ESC delay
- **tui**: Readable on light terminals and in 16 colors; tests + notes
- **prompt**: Opt-in vi mode, chained zle widgets, fork-free git branch
- **build**: Profile per-tool rows from core now that lazy.<ext> is gone
- **alias**: Allow hyphens in alias names
- **init**: Never install a stale .zcompdump.zwc
- **release**: Sync README/site version on release, fail CI on drift
- **cli**: Help and usage text match behavior; unknown actions exit 64
- **init**: Restore wayu PATH order at first prompt; remove build eval
- **prompt**: Set the native prompt again at the first prompt
- **secrets**: Drop entries.json backups holding a converted value
- **const**: List each suggested name once on a get miss
## [5.0.0] - 2026-11-08

### ⚠ Upgrade notes

- **doctor**: `wayu doctor` now exits 78 when any check reports an
error (was always 0). `wayu doctor --fix` requires --yes (or --dry-run)
and exits 64 without it. `doctor --fix` no longer installs wayu into
/usr/local/bin or generates turbo.zsh; a missing turbo.zsh is no longer
reported unless a startup file sources it. `doctor --json` now prints
JSON (combining it with --fix exits 64). `doctor --optimize` was
removed (exits 64); use `wayu export` for a single-file init. With
ZDOTDIR set, `wayu init` writes to $ZDOTDIR/.zshrc.
- **prompt**: `$(...)`, backticks, `$VAR` and quotes in [prompt]
values (format, symbols, contexts, rprompt_format) are printed as typed
instead of being executed/expanded. Prompt `%` escapes and wayu's module
variables still work. Keybinding values containing `'` are now quoted
literally.
- **prompt**: The native wayu prompt, its vi keymap/KEYTIMEOUT,
zle widgets and precmd hooks are off by default. To keep them, add to
- **plugin**: Plugin rm on a symlinked plugin removes only the link.
Invalid plugins.json entries make plugin commands exit 78; enums are
stored as names ("shell": "ZSH"). http:// and git:// plugin URLs are
refused (exit 65). plugin check exits 74 when any remote cannot be read.
plugin update resets clean checkouts after upstream force-pushes and
refuses dirty/symlinked ones. See docs/UPGRADING.md "Unreleased".
- **migrate**: `wayu migrate` is now all-or-nothing. If any legacy line
cannot be converted exactly, or an entry fails validation, it lists the
lines and exits 65 without writing wayu.toml or archiving anything
(including with --dry-run). Previously such lines were silently dropped
and the files archived. Move kept shell code to extra.<ext> or rewrite
it, then re-run. `wayu migrate --from X --to Y` now requires wayu.toml
(exit 78 otherwise; run `wayu --shell X migrate` first), updates
[shell] type, and generates init/core files for the target shell instead
of writing translated aliases/constants/path/init/tools.<ext> copies.
- **completions**: `wayu completions generate|zsh|bash|fish` output changed:
all commands and parser aliases are completed; bash no longer offers the
same action list for every command.
- **init**: [aliases] are defined after plugins/lazy/tools/extra, so
functions there no longer expand wayu aliases in their bodies. nvm's
default node may change (highest matching version, aliases followed).
zsh may delete and rebuild ~/.zcompdump when wayu's completions change.
An edited init.<ext> is no longer replaced; move it aside and run
`wayu init` to adopt a new template. See docs/UPGRADING.md.
- **cli**: Unknown options now exit 64 instead of being ignored.
A trailing --dry-run/--yes/--json/--no-color on `alias add`/`const add`
is a flag; put `--` before the value to keep it (`wayu alias add hd --
helm install --dry-run`).
- **hooks**: A placeholder inside single quotes in hooks.conf is no
longer substituted by wayu; it is passed to an inner shell as
"$WAYU_HOOK_*". Use double quotes for direct substitution. pre_* hooks
no longer run for invalid, missing or no-op operations.
- **backup**: Only the newest 5 backups per file survive any write;
a command makes one backup per file; a default `backup restore` skips
[pre-restore] snapshots (undo a restore with `backup restore <type> 1`).
- **export**: `export --eval/--check` no longer write the turbo file;
`export --check` exits 78 when stale; `export list` no longer generates;
unknown export modes / build targets and fish exports exit 64.

### Added

- **prompt**: Make the native zsh prompt opt-in via [prompt] enabled

### Fixed

- **doctor**: Real --json, safe --fix, exit status, startup-file detection
- **watch**: Free watcher temp allocator each poll; drop pid file on signal
- **prompt**: Keep [prompt] text literal; private async temp dir
- **plugin**: Harden plugin rm, plugins.json, check/update, URLs
- **migrate**: Exact shell parsing, all-or-nothing import, rebuild on shell switch
- **completions**: Generate wayu's completions from one command table
- **init**: Robust generated shell, nvm resolution, compdump refresh, keep edited init
- **cli**: Reject unknown flags; trailing --dry-run on add is a flag
- **hooks**: No value splicing into nested shells; no phantom pre-hooks
- **backup**: Prune to 5 on every write; restore can pick a backup
- **export**: Parse --eval/--check/--turbo; refuse fish; honest help
## [4.4.5] - 2026-11-07

### Fixed

- **tui**: Captured subprocesses can't read the TUI's terminal
## [4.4.4] - 2026-11-07

### Fixed

- **init**: Replace wayu() shell wrapper with prompt-hook PATH sync
- **build**: Restore HOME after unit tests; check git results in release
- **io**: Atomic writes for wayu.toml, plugins.json and generated files
- **plugin**: Lock plugins.json writes; TUI install aborts on bad read
- **toml**: Edit wayu.toml entries in place, keep order, lock writers
- **security**: Owner-only modes for backups and secret-bearing files
- **get**: Exact-match only; misses exit 65 with name-only suggestions
- **security**: Mask secret values in dry-run, search and export previews
- **validation**: Reject ':' and newlines in PATH entries (OKAMI-214)
- **path-sync**: Preserve $? in prompt hooks and support nounset (OKAMI-209, OKAMI-210)
- **path-sync**: Only remove dirs wayu added; keep [paths] order on add (OKAMI-211)
- **init**: Regenerate every initialized shell's files (OKAMI-212)
- **path-sync**: Expand [paths] in-shell; build/config edit/hand edits reach path_sync (OKAMI-213)
- **path-sync**: Hook regenerates with the binary that generated core
- **init**: Build eval targets the evaluating shell; never write as root
- **init**: Never install a .zwc compiled from a superseded source
- **init**: A rewritten init file always wins over its .zwc
## [4.4.3] - 2026-11-07

### Changed

- **init**: Use shared toml line helpers and growing arena
- Remove dead form/input widgets; fix TUI test binary

### Fixed

- **path**: Resolve relative/~/$VAR paths in add and rm
- **conda**: Lazy-load only on conda/mamba, keep root global
- **prompt**: Reset zsh options in context detection
- **lock**: Own all parsed lock file strings
- **plugin**: Single-quote paths in generated loader
- **plugin**: Honor dry-run and own version in migration
- **plugin**: Exact lookups, safe names, owned resolver output
- **plugin**: Safe rm/add/update/check command handlers
- **backup**: Unique sub-second backups, safe restore, JSON escaping
- **migrate**: Strict args, dry-run, safe archiving and real TOML parsing
- **doctor**: Check/fix wayu.toml paths, growable arena, real TOML check
- **fuzzy,search**: Safe raw mode, UTF-8 matching, allocator misuse
- **tui**: Always restore terminal on exit, signals and panics
- **style**: Unify display width, fix dangling returns and leaks
- **form**: Q no longer cancels, EOF exits, keep scrollback
- **tui**: Act on the right row, decode input fully, wide chars, NO_COLOR
- **config**: Parse TOML values and headers correctly
- **path,hooks**: Toml-native clean/dedup, safe hooks, honest dry-run
- **cli**: Flag positions, init/function safety, export hooks
- **toml**: Growable parse arena; entries read from wayu.toml
- **tui**: Parse [env] values with shared TOML kv parser
- **init**: Generate bash-valid, safely quoted init files
- **export**: Build turbo/eval from wayu.toml and honor --dry-run
- **env_snapshot**: Per-cache init flags, piped alias capture
- **completions**: Run _wayu on first autoload
- **init**: Parse [tools] without fixed 512KB arena
- **prompt**: Strip only a matching quote pair from config values
- **doctor**: Recognize eval "$(wayu build eval)" as sourcing wayu
## [4.4.2] - 2026-08-03

### Fixed

- **toml**: Reject malformed config
## [4.4.1] - 2026-07-26

### Changed

- Consolidate all wayu files into ~/.config/wayu
## [4.4.0] - 2026-06-19

### Added

- **function**: Add `wayu function` command + relocate functions dir
## [4.3.4] - 2026-06-09

### Changed

- Consolidate rune width logic into style.odin

### Fixed

- **toml,path**: Repair TOML prefix corruption + stale cache; refresh XDG test paths
## [4.3.3] - 2026-06-06

### Changed

- Consolidate duplicated config-entry and ANSI-strip logic
## [4.3.2] - 2026-05-19

### Changed

- **core**: TOML content cache, async zcompile, zero-alloc line iterator
- **alias**: Defer shell spawn to --full, eliminate unused allocations
- **shell**: Ioctl(TIOCGWINSZ) replaces stty subprocess, zero-alloc detect
- **render**: Zero-alloc visual_width, eliminate redundant table recalc
- **commands**: Cached reads, hash lookups, zero-alloc parsers

### Fixed

- Replace edit icon with nf-fa-edit (U+F044)
## [4.3.1] - 2026-05-15

### Fixed

- **docs**: Fix double line spacing and pretty-print doctor JSON
## [4.3.0] - 2026-05-15

### Added

- **build**: Auto-sync landing page version on release
- **build**: Sync README version on release

### Fixed

- **docs**: Correct landing page content against codebase
- **docs**: Preserve whitespace in terminal body for JSON indentation
## [4.2.0] - 2026-05-15

### Added

- Hide external entries by default, add --full/-f flag

### Changed

- Rename g_ctx→wayu, init-*→base names, add XDG data dir

### Fixed

- Remove hooks help format string bug, hide login.zsh from build output when not generated
- Add consistent emoji headers to alias and constants list output
- Add emoji headers to alias/constants list, fix data dir creation and integration tests
- TUI bugfixes for counts and hooks view
- Use table format for path ls, matching alias/constants style
- Use separate status column for path ls instead of ✗ prefix
- Filter noisy system env vars from constants list
- Strip ANSI escape codes from env var values in table
- Replace newlines in env var values to prevent table row breaks
- Strip_ansi shortcut was skipping newline replacement
- Move path status column from left to right of path
- Hide Source column when only wayu entries shown
## [4.1.1] - 2026-05-10

### Changed

- Remove dead code (lock, fuzzy, style, completions, theme)
- Fix broken test suites
- Remove dead code from toml.odin (1844→1234 lines)
- Consolidate 73→47 source files
- Final consolidation + AGENTS.md update

### Fixed

- Respect --shell flag in init command
## [4.1.0] - 2026-05-09

### ⚠ Upgrade notes

- **toml**: [[paths]]/[[aliases]]/[[constants]] removed.
Run `wayu migrate --schema` to upgrade.

### Added

- **landing**: V3 refresh, favicons, polish pass

### Changed

- **toml**: Hard-break schema, single-bracket tables
- Merge TUI package, unify entry ops, consolidate modules
- General cleanup
## [3.15.0] - 2026-05-06

### Added

- **profile**: Per-phase breakdown of init-core.zsh via EPOCHREALTIME

### Changed

- Code-review polish — split modules, purge dead code, fix leaks
- Replace globals with g_ctx struct, split TUI views
- Cut shell startup from 520ms to 115ms

### Fixed

- **tui**: Correct settings_view navigation in responsive tests
- **env**: Unify [constants] and [env] into single [env] section
- **prompt**: Restore odin detection, fix RPROMPT escaping
## [3.14.1] - 2026-04-23

### Fixed

- **memory**: Eliminate all tracked-allocator leaks (68 -> 0)
## [3.14.0] - 2026-04-23

### Added

- **fuzzy**: Subsequence matching + score-sorting in interactive pickers
## [3.13.0] - 2026-04-23

### Added

- **build**: Implement 'wayu build profile' as a real timer
## [3.12.0] - 2026-04-23

### Added

- **init**: Auto-regenerate init-core; init.ext fast-paths to it
## [3.11.1] - 2026-04-23

### Fixed

- **templates,fish**: Route through wayu.toml + read [constants] as env
## [3.11.0] - 2026-04-23

### Added

- **completions**: Shell-aware naming for add/remove/list
## [3.10.1] - 2026-04-23

### Fixed

- **reload**: Make status/stop work on macOS + BSD
## [3.10.0] - 2026-04-23

### Added

- Implement doctor command, fuzzy plugin matching, and config scan
- Implement adaptive SIMD/GPU optimization system
- Implement wayu build --eval for optimized shell startup
- Complete wayu build eval with real config parsing
- Pre-compute Starship, Zoxide, Atuin in eval mode
- Inline Starship, lazy load rest of tools
- Cache eval output to init-cache.zsh
- Implementa TODAS las optimizaciones de zsh en wayu build
- Prompt nativo wayu pre-compilado sin starship
- Prompt nativo completo con todos los modulos de starship
- Soporte para newline (\n) en prompt format
- Iconos Nerd Fonts de Starship + nuevos lenguajes
- 20+ lenguajes con iconos Nerd Fonts/Unicode
- Iconos Nerd Fonts exactos de nerd-font-symbols.toml
- Modo VI visual completo con selección de texto
- Modo visual con símbolo y color diferentes
- Colores VI mode personalizados - naranja/verde/púrpura
- Línea separadora entre output y prompt
- Prompt con marco decorativo - líneas arriba y abajo con espacios
- Líneas divisorias continuas con espacios alrededor del prompt
- Mostrar versión de lenguaje en el prompt
- Icono Odin Nerd Font - símbolo sin fondo azul
- SVG limpio de Odin para Fontello
- **prompt**: Show lang version in context icon for Rust, Node, Go, Python, Zig, Bun, Deno, Ruby, Elixir, Dart
- **init**: Export all [env] vars from wayu.toml dynamically
- Add 'env' alias for constants command
- **init**: Generate aliases from wayu.toml [[aliases]] dynamically
- Expand TOML-driven config to aliases, constants, and plugins
- **cli**: Wire reload/hot-reload command
- **config**: Honor WAYU_CONFIG_DIR env var for config directory
- **env**: Add snapshot module for PATH/aliases/env cross-reference
- **cli**: Show source column in path/alias/constants list commands
- **cli**: Add --json output for list commands
- **cli**: Surface external entries from env not in wayu.toml
- **doctor**: Report wayu vs env sync status
- **tui/bridge**: Expose source classification per entry
- **tui**: Header counts + per-row source glyphs in list views
- **tui**: Footer hint update for source filter (s key)
- **completions**: Add bash completion generator
- **shell**: Complete fish shell support across init + completions
- **init**: Emit wayu.toml scaffold alongside shell init files
- **scan**: Implement --fix to import shell rc declarations
- **build**: Implement profile subcommand
- **migrate**: Implement legacy-to-TOML migration (dry-run)
- Improve path-missing warning format with colored output
- Add fuzzy-match fallback to env/alias/path get commands
- Extend search to match on entry values in addition to names
- **tui**: Source filter cycled with `s` in data views
- **tui**: Parse `source:X` token inline in text filter
- **plugins**: Complete fish shell support (types, registry, generator)
- **migrate**: Implement legacy-layout → wayu.toml conversion
- **tui**: Settings view shows real data (version, toml, backups, plugins)
- **json**: Fix --json on alias/constants, extend to backup/plugin
- **completions**: Write wayu.fish alongside zsh + bash on generate
- **fish**: Native init-core.fish generator
- **migrate**: Recognize fish syntax in legacy parsers
- **migrate**: Shell-to-shell conversion supports fish

### Changed

- Wayu.toml is now single source of truth
- Wayu build eval is now just 'source init.zsh'
- Config de usuario ahora en config.zsh, no hardcodeada
- Eliminar comandos lentos del prompt para reducir tiempo de carga
- Migrate PATH to wayu.toml, remove icon tooling
- **init_generator**: Add per-segment coloring to path-missing warning
- **toml**: Make `toml convert` an alias for `wayu migrate`
- **toml**: Alias/constants/path writes always target wayu.toml
- **backup,dry-run**: Align with wayu.toml as source of truth

### Fixed

- **doctor**: Use arena allocator for memory safety
- Add missing components to wayu build eval
- Generate absolute PATH without accumulation
- Load plugins inline in eval mode
- Remove heavy inline starship, lazy load everything
- Remove background subshell that broke shell
- Load helpers before using _wayu_evalcache
- Arregla PATH incompleto y plugins no cargaban
- Añade bindkeys para autosuggestions (Ctrl+Y)
- Añade || true a sources condicionales para evitar error exit code
- Glob errors y funcion prompt faltante
- Prompt exit_code y VI mode correctos
- Modo visual detection y color naranja 256-color
- Detector de contexto busca archivos en subdirectorios
- Mover detector Odin antes que Nim y usar find para ambos
- Líneas separadoras correctas con cursor en el prompt
- Usar $'\n' para newline literal en PROMPT
- Mover detector Go antes que Nim para evitar falsos positivos
- Usar código \ue800 para icono Odin de Fontello
- Eliminar caracteres < > del output de wayu build eval
- Usar emoji ⚔️ para Odin en lugar de icono Nerd Font
- Detector Odin compatible con bash y zsh
- **hooks**: Implement hook execution and editor integration
- **toml**: Allow hyphens in alias names
- **tui**: Add Hooks entry to main menu
- **cli**: Recognize --help/-h flag for all subcommands
- **tui**: Load PATH, Aliases, Constants from wayu.toml
- **tui**: Replace Settings view placeholders with real values
- **toml**: Implement show/keys actions to display TOML content and keys
- **reload**: Add --help support and make reload print 'watching' message
- **toml**: Parse [[paths]] array of tables in TOML config
- **shell**: Emit bash-specific syntax instead of zsh in init generation
- **hooks**: Add missing 'run' action to hooks help text
- **hooks**: Integrate hook execution into add/remove flows
- **validation**: Sanitize shell metacharacters in alias/constant values
- **config**: Clarify default action and list available subcommands
- **tui**: Replace hooks placeholder with helpful guidance
- **validation**: Idempotent sanitize preserving $ expansion
- **hooks**: Distinguish hook types by resource and fix string memory bug
- **tui**: Align backup list filtering with CLI behavior
- **toml**: Preserve escape sequences when reading and writing TOML values
- **toml**: Preserve [env] section through constants writer round-trip
- **init**: Do not block on interactive prompt when stdin is not a TTY
- **toml**: Do not duplicate [env] entries into [constants] on write
- **env_snapshot**: Clone PATH strings to prevent dangling pointers
- **env_snapshot**: Parse alias subshell output and match by name
- **tui**: Constants view must merge [env] and [constants] sections
- **tui**: Preserve alias name column when rendering source glyph
- **tui**: Remove s Source hint from all footer variants
- **tui constants**: Add external entries classification to match CLI output
- **tui**: Clear full row width in list rendering to prevent scroll overlap
- **tui**: Scroll offset applied correctly to viewport render
- **tui**: Move source glyph color from char stream to Cell.fg
- **init_generator**: Lowercase 'path' in missing-path warning message
- **search**: Read from wayu.toml instead of legacy shell files
- **reload**: Delete path strings only when not handed off to watch array
- **tui**: Main menu item count was 7 but there are 8 items
- **init**: Avoid freeing string literal in generate_full_prompt
- **completions**: Repair broken wayu.fish top-level completion
- **validation**: Reject hyphens in alias/constant identifiers
- **fish**: Repair shell_fish generators and route static_generate to fish
- **memory**: Overhaul TOML/lock/config cleanup to prevent bad frees
## [3.9.0] - 2026-04-15

### Added

- Implement all requested features
## [3.8.0] - 2026-04-15

### Added

- **toml**: Expose TOML commands to CLI
## [3.7.1] - 2026-04-15

### Changed

- **export**: Rename turbo file to turbo.zsh
## [3.7.0] - 2026-04-15

### Added

- **export**: Add turbo export mode for faster shell startup
## [3.6.0] - 2026-04-15

### Added

- Add shared interfaces for parallel workstreams
- **search**: Add global fuzzy search commands
## [3.5.0] - 2026-04-09

### Added

- Add 'wayu config' command to edit extra config in $EDITOR
## [3.4.0] - 2026-04-09

### Added

- Integrate extra.zsh as a managed config file
## [3.3.0] - 2026-04-09

### Added

- Make TUI the default when running 'wayu' with no arguments
- **tui**: Responsive layout with breakpoints and dynamic dimensions

### Fixed

- **tui**: Use select() with 50ms timeout for non-blocking event polling
## [3.2.0] - 2026-03-20

### Added

- Rename landing to docs to use on github pages
- Add SVG favicon with transparent background for landing page
- Add release target to build script — tests + tag + push to trigger CI
- Add git-cliff for automatic CHANGELOG generation on release
- Add wayu constants get command ([#3](https://github.com/dvrd/wayu/pull/3))
- Add 'const' as alias for 'constants' command ([#5](https://github.com/dvrd/wayu/pull/5))
- Automatic changelog and versioning system

### Fixed

- Source plugins/config.zsh in shell init templates for both zsh and bash
- Add og:image meta tags and screenshot
- Mention 'const' alias in wayu help output ([#5](https://github.com/dvrd/wayu/pull/5))
## [3.1.0] - 2026-02-26

### Added

- Expand environment variables and relative paths in PATH operations
- More updates and fixes
- Add TUI detail overlay views and inline fuzzy filter
- Update gitignore
- Add TUI notification system with auto-dismiss
- **tui**: Add two-column table layout for alias and constants views
- Multiple updates
- Optimize shell templates for fast startup + fix TUI buffer reuse
- **tui**: Dashboard-style main menu with accent bars and dividers
- **tui**: Dashboard views, delete confirmation modal, vim keys, arena memory
- **tui**: Focusable delete modal buttons with h/l navigation and Enter to confirm
- **tui**: Add modal for PATH/ALIAS/CONSTANTS + orange focused button highlight
- **tui**: Focus-aware add modal + Tab navigation in both modals
- Replace Taskfile with bld build system
- **plugin**: Document search action, remove dead dfs_visit_with_priority, update README
- **plugin**: Expand registry to 54 plugins with category search
- **tui/plugin**: Wire registry load + install into TUI bridge
- Show external alias sources in alias list via alias-sources.conf

### Changed

- Extract truncate_to_width, merge enable/disable, add PATH ops tests
- Consolidate layout/theme into style.odin, add subprocess module, clean up TUI and plugin layers

### Fixed

- Harden shell injection, decompose plugin, add tests and docs
- Rewrite screen_flush with active-state ANSI tracking to fix TUI color bleeding
- Migrate to new Odin core:os API (dev-2026-02)
- **tui**: Memory safety and UB fixes for release builds
- **tui**: Responsive terminal size with 3-method fallback
- **tui**: Cursor persistence bug and visual delete confirmation buttons
- **tui**: Modal button margin, border overlap, and no-background button style
- **tui**: Add extra blank row between modal body and buttons
- **tui**: Move extra modal margin above buttons, not below
- **tui**: H/l type freely in fields; bordered box input indicator
- Eliminate all memory leaks and bad frees (116 -> 0)
- CI failures — bad free in plugin config, missing dirs, AGENTS.md check, single-threaded tests
- Code review fixes — self-rebuild mtime bug, install/dev run built binary, extract bin_path()
- Code review — arena allocs, shell-ext hardcode, parse_args dedup, table theme colors, plugin map global
- Code review — circular dep check result, backup no-op semantics, validate_constant stdout side effect
- **tui**: Viewport follows cursor in list views
- **tui**: Reserve scroll-indicator row so last item is never hidden
- **tui**: Main menu clips to terminal bounds and scrolls with cursor
- **plugin**: Memory leak in check loop, swallowed loader error, duplicate bridge procs
- **tests**: Isolate Ruby integration tests to /tmp, never touch real config
- **tui**: Registry tab always loads + clean exit with no residue
- **tui**: Tab and Enter keys never reached plugins view handler
- TUI plugin install from Registry tab end-to-end
## [3.0.0] - 2025-11-09

### ⚠ Upgrade notes

- Migrate from function-based to array-based PATH management

## What Changed
- Old Format (v2.x): Individual `add_to_path "/path"` function calls
- New Format (v3.0.0): Centralized array `WAYU_PATHS=("path1" "path2")`

## Why This Change
The old format had a critical bug: `wayu path add` appended entries to EOF,
AFTER all `export PATH=` statements had executed. This made newly added
paths ineffective until manually moved.

The new array-based system solves this by:
1. All paths declared in single WAYU_PATHS array
2. Single for-loop processes all entries and exports PATH once
3. New paths inserted INSIDE array (before closing paren)
4. All paths guaranteed to be processed and exported correctly

## Implementation Details

### Phase 1: Templates and Parsers
- Updated PATH_TEMPLATE in preload.odin (zsh and bash versions)
- Updated PATH_SPEC parser to parse quoted array elements
- Updated PATH_SPEC formatter to format as `  "/path"`

### Phase 2: Insertion Logic
- Smart array insertion in config_entry.odin
- Line-by-line search to find correct closing paren
- Insert before `)` of WAYU_PATHS array

### Phase 3: Tests
- Updated unit tests (test_path.odin) to parse array format
- All integration tests passing (7 PATH tests)
- Core test suites validated

### Phase 4: Documentation
- README.md updated with breaking changes section
- Migration guide included with two options
- Full code examples for manual migration

## Files Modified
- preload.odin: New PATH templates with array format
- config_specs.odin: Updated PATH_SPEC parser and formatter
- config_entry.odin: Smart array insertion logic
- path.odin: Added dynamic-literals feature flag
- plugin.odin: Added dynamic-literals feature flag
- main.odin: Fixed DETECTED_SHELL initialization
- test_path.odin: Updated tests for array parsing
- test_plugin.odin: Plugin test updates
- test_plugin.rb: Integration test updates
- README.md: Breaking changes section and migration guide

## Migration Required
Users upgrading from v2.x must either:
1. Reinitialize with `wayu init` and re-add paths
2. Manually convert path files to new array format

## Test Results
✓ 7 unit tests passing (PATH parsing and validation)
✓ 7 integration tests passing (PATH operations end-to-end)
✓ Core test suite validated

### Added

- Implement Phase 1 of plugin system enhancement (PRP-15)
- Implement completions view and apply layout constants across all TUI views
- Implement Phase 3 plugin enable/disable (PRP-15)
- Implement Phase 4 dependency management (PRP-15)
- Implement array-based PATH system (v3.0.0)

### Changed

- Remove tui_ prefix from files in src/tui/ directory
## [2.2.0] - 2025-10-16

### Added

- Implement comprehensive style system and UI components
- Integrate style system across all commands
- Implement vibrant color system with TrueColor support (PRP-09 Phase 1)
- Replace Charm colors with Zellij 'dvrd' theme (PRP-09 Phase 1)
- Enhance visual aesthetics with colored symbols and curved table borders
- Implement PRP-09 Phase 2 - Interactive Add Commands (TUI mode)
- Add container border to interactive forms
- Add interactive TUI mode to alias and constants commands
- Complete PRP-07 style system render pipeline
- Integrate style system with all help commands (PRP-07 100%)
- **tui**: Implement Phase 3 enhanced fuzzy finder foundation
- **tui**: Integrate enhanced fuzzy finder into path list command
- **tui**: Integrate enhanced fuzzy finder into alias list command
- **tui**: Integrate enhanced fuzzy finder into constants list command
- Phase 5 - Terminal state safety with termios
- Add Vim-like modal keybindings and confirmation prompts
- Implement full TUI mode with memory bug fixes (PRP-12)
- Implement PRP-11 command handler abstraction
- Add TUI component system and box generator tools
- Add component testing infrastructure (PRP-13)
- Add component testing infrastructure (PRP-13)

### Changed

- Improve memory management and UI consistency
- Remove shell script integration tests in favor of Ruby tests

### Fixed

- Resolve shell detection global variable initialization order
- Initialize HOME and WAYU_CONFIG in init_shell_globals
- Make init_shell_globals idempotent to prevent parallel test race conditions
- Correct emoji alignment, validation triggering, and memory leaks in forms
- Improve emoji width detection with precise Unicode ranges
- Resolve memory leak from double-free of validation strings
- Clone string literals to prevent freeing unallocated pointers
- Table rendering and help commands
- Simplify backup, plugin, and migrate help commands
- **tui**: Fix alignment issues in fuzzy finder rendering
- **tui**: Add carriage returns for raw mode terminal rendering
- **tui**: Improve alignment and add keyboard actions to list commands
- Resolve fuzzy finder delete actions and title alignment issues
- Correct border alignment in fuzzy finder list and details panels
- Correct border alignment to match 62-char line width
- Correct termios struct for macOS compatibility
- Resolve unit test failures and improve test robustness
- Rename run_component_test to run_component_testing
## [2.0.0] - 2025-10-12

### ⚠ Upgrade notes

- Wayu now supports both Bash and ZSH with automatic shell detection

- Add semantic versioning system with VERSION constant
- Implement automatic shell detection with manual override (--shell flag)
- Add shell-aware configuration file naming (path.bash vs path.zsh)
- Add migration command (wayu migrate) for converting between shells
- Add version command (wayu version, -v) for version information
- Add dry-run flag support (--dry-run, -n) for preview mode
- Add backup command integration for safe configuration management
- Update help system with version display and new commands
- Maintain backward compatibility with existing ZSH configurations

Major version bump to 2.0.0 due to multi-shell architecture changes.

### Added

- Initial implementation of wayu
- Add wayu init command for setup
- Add test coverage reporting with Ruby script
- Add input validation and sanitization (PRP-01)
- Add enhanced error handling system (PRP-02)
- Add completions command and convert tests to Ruby (PRP-03)
- Add shell detection and backup system for multi-shell support
- Add shell-specific configuration templates
- Implement multi-shell support and migration system (v2.0.0)
- Update command handlers for multi-shell compatibility

### Changed

- Clean up code and improve error handling
[6.0.0]: https://github.com/dvrd/wayu/releases/tag/v6.0.0
[5.0.0]: https://github.com/dvrd/wayu/releases/tag/v5.0.0
[4.4.5]: https://github.com/dvrd/wayu/releases/tag/v4.4.5
[4.4.4]: https://github.com/dvrd/wayu/releases/tag/v4.4.4
[4.4.3]: https://github.com/dvrd/wayu/releases/tag/v4.4.3
[4.4.2]: https://github.com/dvrd/wayu/releases/tag/v4.4.2
[4.4.1]: https://github.com/dvrd/wayu/releases/tag/v4.4.1
[4.4.0]: https://github.com/dvrd/wayu/releases/tag/v4.4.0
[4.3.4]: https://github.com/dvrd/wayu/releases/tag/v4.3.4
[4.3.3]: https://github.com/dvrd/wayu/releases/tag/v4.3.3
[4.3.2]: https://github.com/dvrd/wayu/releases/tag/v4.3.2
[4.3.1]: https://github.com/dvrd/wayu/releases/tag/v4.3.1
[4.3.0]: https://github.com/dvrd/wayu/releases/tag/v4.3.0
[4.2.0]: https://github.com/dvrd/wayu/releases/tag/v4.2.0
[4.1.1]: https://github.com/dvrd/wayu/releases/tag/v4.1.1
[4.1.0]: https://github.com/dvrd/wayu/releases/tag/v4.1.0
[3.15.0]: https://github.com/dvrd/wayu/releases/tag/v3.15.0
[3.14.1]: https://github.com/dvrd/wayu/releases/tag/v3.14.1
[3.14.0]: https://github.com/dvrd/wayu/releases/tag/v3.14.0
[3.13.0]: https://github.com/dvrd/wayu/releases/tag/v3.13.0
[3.12.0]: https://github.com/dvrd/wayu/releases/tag/v3.12.0
[3.11.1]: https://github.com/dvrd/wayu/releases/tag/v3.11.1
[3.11.0]: https://github.com/dvrd/wayu/releases/tag/v3.11.0
[3.10.1]: https://github.com/dvrd/wayu/releases/tag/v3.10.1
[3.10.0]: https://github.com/dvrd/wayu/releases/tag/v3.10.0
[3.9.0]: https://github.com/dvrd/wayu/releases/tag/v3.9.0
[3.8.0]: https://github.com/dvrd/wayu/releases/tag/v3.8.0
[3.7.1]: https://github.com/dvrd/wayu/releases/tag/v3.7.1
[3.7.0]: https://github.com/dvrd/wayu/releases/tag/v3.7.0
[3.6.0]: https://github.com/dvrd/wayu/releases/tag/v3.6.0
[3.5.0]: https://github.com/dvrd/wayu/releases/tag/v3.5.0
[3.4.0]: https://github.com/dvrd/wayu/releases/tag/v3.4.0
[3.3.0]: https://github.com/dvrd/wayu/releases/tag/v3.3.0
[3.2.0]: https://github.com/dvrd/wayu/releases/tag/v3.2.0
[3.1.0]: https://github.com/dvrd/wayu/releases/tag/v3.1.0
[3.0.0]: https://github.com/dvrd/wayu/releases/tag/v3.0.0
[2.2.0]: https://github.com/dvrd/wayu/releases/tag/v2.2.0
[2.0.0]: https://github.com/dvrd/wayu/releases/tag/v2.0.0

