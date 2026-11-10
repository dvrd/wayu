# Upgrading wayu

User-visible behavior changes per release. From 4.4.5 on, these are generated
automatically from breaking commits ("⚠ Upgrade notes" in `CHANGELOG.md`);
4.4.3 and 4.4.4 shipped them as patch releases, so they are listed here.

## Unreleased

**Generated shell code and startup**

- core.<ext>: the Secrets section runs after the PATH apply, and its
  cache-miss `wayu secrets cache` call (like the prompt hook's `wayu build`)
  uses wayu's absolute path, also when wayu was run by bare name from
  `PATH` (was a bare `wayu`, not found in shells with a minimal PATH: cron,
  GUI apps, ssh commands). Run `wayu build` once to regenerate.
- The prompt hook's `wayu build` (after a hand edit of `wayu.toml` /
  `entries.json`) no longer compiles stale scripts while the prompt waits:
  it starts `wayu script build` in the background (a Swift script froze the
  prompt for ~10 s).
- `wayu build` regenerates `plugins.<ext>` from `plugins.json` for every
  set-up shell (a hand edit, e.g. disabling a plugin, had no effect until a
  `wayu plugin` command ran), and exits `78` naming the file when
  `plugins.json` is invalid (was silent, exit 0); the plugin loaders are then
  kept as they were. `plugins.<ext>` no longer has a `# Last updated` line.
- core.zsh no longer sources `plugins/zsh-autosuggestions` /
  `plugins/zsh-syntax-highlighting` on its own when their checkouts exist:
  only plugins enabled in `plugins.json` load (`wayu plugin disable` had no
  effect on those two). A checkout not registered in `plugins.json` is no
  longer loaded: register it with `wayu plugin add`.
- bash: a `[tools]` word `zsh` / `--zsh` in `args` becomes `bash` /
  `--bash` in core.bash, as fish already did (`args = "init zsh"` put
  `zoxide init zsh` into core.bash; bash 3.2 failed on its output). In
  core.zsh, `bash` / `--bash` likewise become `zsh` / `--zsh`.

**One status icon per line**

- `path add` / `path remove` print `✓ Added to PATH: <dir>` / `✓ Removed
  from PATH: <name>` (no extra `✅`). `plugin check` / `plugin update` put
  the indent before the line's icon and drop the second one (`  ✓ Up to
  date`, `  ℹ Update available: a → b`, `  ⚠ Failed to check remote …`).
  Scripts matching the old text with the emoji need updating.

**zsh startup: interactive-only parts skipped in non-interactive shells; compinit guard**

- Non-interactive zsh (`zsh -c`, scripts; wayu loaded from `.zshenv`) no
  longer loads plugins (`plugins.zsh`, the zsh-autosuggestions /
  zsh-syntax-highlighting fallbacks, `plugins/config.zsh`) or sets up
  zsh-defer; `zsh-defer` is a no-op there (nothing ever drained its queue
  outside a prompt). Constants, secrets, PATH, `functions/`, `[tools]`,
  `tools.zsh`, `extra.zsh` and aliases still load. `zsh -c true` with a
  typical setup: ~20 ms → ~8 ms.
- After wayu's `compinit`, a later `compinit` call (an installer's
  `autoload -Uz compinit && compinit` in `.zshrc`) no longer redoes the
  completion setup: it only registers the completions of `fpath` dirs added
  since, ignoring its flags; the same registration runs at the first prompt.
  `[settings] compinit_guard = false` restores zsh's own `compinit`.
- `.zcompdump` is also rebuilt when any `fpath` dir (or its mtime) changed,
  so completions installed into brew's/the system's `fpath` dirs show up in
  the next shell (were only picked up after wayu's own completions changed).
- zsh-defer runs queued commands once the prompt is drawn and the line
  editor is idle (a `zle -F` handler), one per idle moment, with errors shown
  (they were run from a precmd hook, before the prompt was drawn, with stderr
  discarded). wayu no longer defines `TRAPUSR1` for it; with the native
  prompt's async data, a `TRAPUSR1` function defined before wayu is kept and
  called first.
- Native prompt: `PROMPT` is `$'\n''${_WAYU_PS1}'`, rendered in the shell
  (precmd, and before the vi-mode / toggle / async `zle reset-prompt`)
  instead of two `$(...)` subshells per render. `_wayu_prompt_full` and
  `_wayu_prompt_transient` set `REPLY` instead of printing; `{localip}` is
  looked up once per prompt.
- Re-sourcing `init.zsh` / `init.bash` in a shell skips plugins already
  loaded in it (`plugins.<ext>` guards each plugin) and doesn't add wayu's
  completions dir to `fpath` again or rerun `compinit`.
- New opt-in `[settings]` keys (zsh): `defer_plugins` (load plugins after
  the first prompt) and `lazy_compinit` (compinit on the first completion).
- New opt-in `[settings] autosuggest = true` (zsh): history suggestions
  (falling back to a `PATH` command name for a first word history doesn't
  match)
  built into `core.zsh` (one redraw hook, 13 accept widgets wrapped instead
  of every widget), styled by `autosuggest_style` (default `"fg=8"`),
  accepted with →/End/`^F`/`^Y` (`autosuggestions_accept_keys`). While it is
  on, the zsh-autosuggestions plugin is not loaded and `wayu doctor` warns if
  it is still enabled. Off by default: nothing changes unless you set it.
- New opt-in `[settings] highlight = true` (zsh): syntax highlighting built
  into `core.zsh` (one redraw hook, no widget wrapped, nothing forks; zsh's
  own lexer; a keystroke at the end of the line re-highlights only the last
  words). Styles use zsh-syntax-highlighting's names and defaults, changed
  with `highlight_styles = { command = "fg=blue", ... }` (or a
  `[settings.highlight_styles]` table). While it is on, the
  zsh-syntax-highlighting and fast-syntax-highlighting plugins are not
  loaded and `wayu doctor` warns if one is still enabled. Off by default.
- Built-in highlighting, checked against fast-syntax-highlighting
  (`tests/highlight_diff`): brackets are colored by depth (new styles
  `bracket-level-1..3`, `bracket-error` for unmatched ones,
  `cursor-matchingbracket` for the pair of the one under the cursor), history
  expansions (`!!`, `!$`, ...: `history-expansion`), `in` after `case` and
  `always` are reserved words, assignments after `typeset` / `local` /
  `export` / `readonly` are `assign`, `command -v NAME` highlights NAME as a
  command, nothing is a glob after `noglob`, `=cmd` is a command, a quoted
  command name is colored as the command, `{fd}` in `{fd}>file` is
  `named-fd` (default none; was `redirection`) and the descriptor in `2>&1`
  is `numeric-fd` (default none). Fixed: `'...'` followed by more text in
  the same word was colored to the end of the word, `&!` lost the rest of
  the line, `$[...]` was a glob, `for x (...)` / `for ((...))`,
  `function name { ... }`, case `(pattern)`, `name=(...)` inside `$(...)`,
  and a stale result after deleting part of a heredoc operator. Lines
  entered at a continuation prompt are now highlighted with the current
  line, and an edit in the middle of a long line no longer re-highlights it
  all (500 characters: ~4 ms → ~0.9 ms per keystroke).

**`wayu optimize`: installer lines in your startup files move into wayu**

- New `wayu optimize [--check] [--dry-run] [--yes]` (see `docs/cli.md`):
  lines after the one that loads wayu (`source <(tool completion zsh)`,
  `eval "$(tool init zsh)"`, `fpath=(dir $fpath)`, a second `compinit`,
  `export PATH=dir:$PATH`, `alias`, `export NAME=value`) are moved into wayu
  and **removed from the file** (backed up first; `wayu backup restore .zshrc
  --yes` undoes it). It needs `--yes` like other commands that rewrite files;
  without it (or with `--dry-run`) it shows the diff.
- `entries.json` has two new optional sections, `fpath` (zsh completion dirs,
  put on `fpath` before `compinit`) and `generators` (cached
  `_wayu_evalcache` calls, emitted in that shell's core only, interactive
  shells only for zsh/bash). New `wayu completions fpath [list|add|rm]`.
- Generated `core.<ext>` has a new prompt hook, `_wayu_rc_check`: when a
  startup file is newer than `<data>/rc_check.stamp` it runs
  `wayu optimize --notify` once and prints
  `wayu: ~/.zshrc changed: N lines can be optimized (wayu optimize)` on
  stderr (once per change; the first prompt after upgrading checks once).
  `[settings] auto_optimize = true` moves the lines instead.
- `wayu doctor` has a new "startup files" check (warning, with an estimated
  cost per shell start; generator commands are run once to time them), and
  `doctor --fix --yes` runs `wayu optimize`.
- `wayu backup restore` accepts a shell startup file (`.zshrc`, `.bashrc`,
  `~/.config/zsh/.zshrc`, or its path).
- `wayu config scan` reads the current shell's rc file (`$ZDOTDIR/.zshrc` when
  ZDOTDIR is set; `.bashrc`/`.bash_profile` for bash, `config.fish` for
  fish) instead of always `~/.zshrc`, so `--fix` writes the blocks to the
  matching `extra.<ext>`; it detects `# >>> … # <<<` installer blocks (conda)
  as one block, and no longer takes a backup of `extra.<ext>` when it has
  nothing to add.

## 6.0.0

**PATH entries, aliases and constants move to `entries.json`; data dir is
`~/.local/share/wayu`**

- The default data dir is now `${XDG_DATA_HOME:-~/.local/share}/wayu`
  (was: the config dir). It holds `init.<ext>`, the generated files,
  `plugins.json`, `plugins/`, `completions/`, `backup/` and the lock.
  `WAYU_DATA_DIR` still overrides it, and no longer follows
  `WAYU_CONFIG_DIR`. `wayu init` creates both dirs.
- The rc line is now
  `source "${WAYU_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/wayu}/init.zsh"`
  (`init.bash` likewise; fish: see the README). Replace the old
  `source "$HOME/.config/wayu/init.zsh"` line; `wayu init` prints the new one.
- `[paths]`, `[aliases]` and `[env]` are no longer read from `wayu.toml`.
  They live in `<data>/entries.json`
  (`{"version":1,"paths":[{"key","dir"}],"aliases":[{"name","value"}],"env":[{"name","value"}]}`),
  written only by wayu (`wayu path|alias|const`, the TUI, templates):
  atomic, owner-only (`0600`), pretty-printed, stable order. A malformed
  `entries.json` makes every command that reads it exit `78` naming the file;
  a missing one is empty.
- Nothing is converted. To upgrade: run `wayu init`, re-add each entry with
  `wayu path add <key>=<dir>`, `wayu alias add <name> <command>` and
  `wayu const add <NAME> <value>` (in the old file order), delete the three
  tables from `wayu.toml`, move `plugins.json` and `plugins/` from
  `~/.config/wayu` to the data dir (or re-add the plugins), and update the rc
  line. `wayu toml validate` (exit `65`) and `wayu doctor` (exit `78`) report
  a leftover `[paths]` / `[aliases]` / `[env]` table with the command to use.
- `wayu toml show` prints `wayu.toml` verbatim; `--reveal` is gone (exit `64`).
- `wayu backup`: types are `toml` (wayu.toml) and `entries`
  (`entries.json`; `path`, `alias` and `constants` name it too). A restore of
  entries reverts all PATH entries, aliases and constants.
- `wayu doctor` has an `entries` check (error when `entries.json` does not
  parse).
- `plugin list --json` conflicts: `with` is `"entries.json"` (was
  `"wayu.toml"`) for a clash with your aliases / constants.
- Messages: `path add` prints `Added to PATH: <dir>`, a missing entry is
  `PATH entry not found: <dir>`, `alias add` prints `Alias added: <name>`,
  dry runs print `Would update entries.json (aliases)` etc.

Notes further down this section that describe `[paths]`, `[aliases]` or
`[env]` in `wayu.toml` (editing, reading, `toml show` masking) now apply to
the same entries in `entries.json`, or no longer apply.

**Functions move to the data dir; new `wayu script`**

- `functions/` now lives in the data dir (`$WAYU_DATA_DIR/functions`), not
  the config dir: `wayu function` writes there, `core.<ext>` sources only
  that dir, and `wayu init` creates it there. Nothing is moved for you:
  `mv ~/.config/wayu/functions/* "${WAYU_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/wayu}/functions/"`.
- New `wayu script` (`scripts`): standalone executables in any language
  (swift compiled with `swiftc`; python, ruby, node, bun, bash, zsh, fish,
  perl, lua, sh linked) in `<data>/scripts/`, run from `<data>/bin/`.
  `wayu init` creates both dirs. Once `bin/` holds a script, `core.<ext>` /
  `path_sync.<ext>` put it first among wayu's PATH entries (zsh, bash,
  fish), so a script can shadow a tool of the same name; `wayu export
  --eval` includes it too.
- `wayu build` and `wayu reload` rebuild stale scripts; `wayu doctor` has a
  `scripts` check (stale or broken scripts, `bin/` entries without a
  script). New exit code `69` (`EXIT_UNAVAILABLE`): `script new` when the
  language's interpreter or compiler is not on PATH.
- wayu.toml accepts `[scripts] default_lang`; an unknown language is a
  `toml validate` error (exit `65`).

**Encrypted secrets (`const add --secret`, `wayu secrets`, `[secrets]`)**

- `wayu const add NAME [VALUE] --secret` stores the value encrypted
  (ChaCha20-Poly1305) in `<data>/secrets.json`; the master key lives in the
  macOS keychain / Secret Service / `<config>/secret.key`
  (`[secrets] backend`). Without VALUE it is read from stdin. `const get`
  decrypts, `const rm` removes, `const list` shows `********` with source
  `wayu (secret)`; in `--json` such a row is
  `{"constant", "secret": true, "source"}` with no `value`.
- Converting a plain constant with `--secret` deletes the entries.json
  backups that still hold its plaintext value.
- A `--secret` at the end of a `const add` line is now a flag, not part of
  the value (like `--dry-run`). To store the literal text, put `--` before
  the value. `--secret` anywhere else exits `64`.
- A plain `const add` of a name that is a secret exits `65`.
- New `wayu secrets list|rekey|lock`. `[secrets]` is a known wayu.toml
  table; an unknown `backend` makes `toml validate` exit `65`.
- When secrets exist, `core.<ext>`, `turbo.<ext>` and `export --eval` get a
  Secrets section after the constants that sources a per-session cache in
  `${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/wayu-<uid>/` (running
  `wayu secrets cache` once when it is stale). Nothing changes for configs
  without secrets.
- `wayu doctor` has a `secrets` check (an `info` row when there are none);
  its message counts run-only secrets.
- Run-only secrets: `wayu const add NAME [VALUE] --run-only` (implies
  `--secret`) stores a secret that is never exported to shells (not in the
  session cache, core, turbo or `export --eval`). `const list` shows it with
  source `wayu (run-only)`, `--json` adds `"run_only": true`. Re-adding with
  `--secret` / `--run-only` switches the mode.
- New `wayu secrets run NAME... -- CMD [ARGS...]`: execs CMD (PATH lookup,
  no shell) with those secrets added to the environment. Exit `64` without
  `--`/names/CMD, `65` for an unknown name, `127` / `126` when CMD is not
  found / not executable; otherwise CMD's own status.
- `wayu secrets list` prints a mode column (`session` / `run-only`) after
  each name.

**`wayu build eval` removed; zsh PATH order restored after login**

- `wayu build eval` is gone (exit 64). It rebuilt every generated file at
  each shell start, which nothing needs: every wayu write regenerates them and
  the prompt hook runs `wayu build` when `wayu.toml` or `entries.json` was
  edited by hand.
  Replace `eval "$(wayu build eval)"` in rc files with the `source` line
  above (or `init.bash`).
  `eval "$(wayu export --eval)"` (env/PATH/aliases only) is unchanged.
- zsh: at the first prompt wayu puts its PATH entries' dirs back in front of the
  dirs that were on PATH when it loaded or that macOS `path_helper` manages
  (`/etc/paths`, `/etc/paths.d`). Loading wayu from `~/.zshenv` therefore
  keeps wayu's PATH precedence in login shells; dirs prepended in `.zshrc`
  stay ahead.
- zsh native prompt: `PROMPT`/`RPROMPT` are set again at the first prompt,
  so `/etc/zshrc` (macOS sets `PS1`) or `.zshrc` can't replace them when wayu
  is loaded from `.zshenv`. To manage the prompt yourself, set
  `[prompt] enabled = false`.

**Removed: backward compatibility**

wayu now reads only the current formats: `wayu.toml`, `entries.json`, `plugins.json`, `hooks.conf`,
`functions/<name>.<ext>`, `extra.<ext>` and the files the current generator
writes. Configs left by older releases are not converted or tolerated any
more. Upgrade from the previous release only.

- `wayu migrate` (legacy shell files → wayu.toml, `--schema`, `--from/--to`)
  and `wayu toml convert` are removed (exit `64`). Use
  `wayu --shell <shell> init` to set up another shell. `wayu build` without a
  `wayu.toml` exits `78`.
- The 3.x `[[paths]]` / `[[aliases]]` / `[[constants]]` schema is no longer
  detected: no exit `78` with a migration hint, no backup-restore refusal.
  `toml validate` rejects it (exit `65`) and `doctor` reports an error.
- `path.<ext>`, `aliases.<ext>` and `constants.<ext>` are neither created by
  `wayu init` nor read: `init.<ext>` sources only `core.<ext>` (and prints a
  `wayu build` hint when it is missing), `core.<ext>` no longer sources
  `path.<ext>`, `wayu watch` no longer watches them, and the TUI/search read
  `wayu.toml` only.
- Only an untouched `init.<ext>` from the previous release is refreshed; an
  older one is treated as edited (kept, with a warning): move it aside and
  run `wayu init`. Leftover `lazy`, `login` and `helpers.<ext>` files are no
  longer deleted.
- `plugins.conf` is ignored (no migration to `plugins.json`). Enum values in
  `plugins.json` must be names (`"zsh"`, `"source"`); numbers fail to load
  (exit `78`). The unused `entry_file` and `profiles` fields are no longer
  written.
- Backups are listed, restored and pruned only under the current name
  (`<file>.backup.YYYY-MM-DD_HH-MM-SS.UUUUUU[-N]`); older names are ignored.
  A backup dir left group/world-readable by an old release is no longer
  tightened (new backups are still `0600` in a `0700` dir).
- Keys wayu never read are no longer parsed: `wayu_version`, `[settings]`
  `auto_backup` / `fuzzy_fallback` / `dry_run_default`, `[path]`
  `dedup` / `clean`, `[[plugins]]`, `[profile.*]`,
  `[prompt.username] style_user`, `[prompt.interactive] async_interval`.
  `toml validate` prints a warning per unknown key or table, with its line,
  and still exits `0`; a known table in the wrong shape (`[[paths]]`,
  `paths = …`) is an error (exit `65`). `doctor` warns about unknown keys.
- A top-level `shell = "…"` in wayu.toml is not read; use `[shell] type`.
- `functions/`: zsh sources only `*.zsh`, bash only `*.bash` (fish already
  `*.fish`); files without that extension are no longer sourced. Functions
  under the old `~/.local/share/wayu/functions` are no longer copied over.

Notes further down this section about `wayu migrate`, the `[[paths]]`
refusal, `plugins.conf` or the legacy shell files describe changes made
before these features were removed; they no longer apply.

**Unknown actions, `wayu toml`**

- `wayu toml` with no action validates wayu.toml (same as `toml validate`,
  as its help always said); it printed a fixed key list.
- `wayu toml keys` lists wayu.toml's real top-level keys and tables in file
  order; it printed a fixed `shell path aliases constants plugins hooks`. A
  file that doesn't parse exits `65`.
- An action word a command doesn't have exits `64` with that command's help
  for `toml`, `hooks`, `config`, `template` and `function` too (they showed
  help or the hook list and exited `0`). `doctor` with a non-flag argument
  exits `64`; `doctor help` shows its help.
- `--source` other than `wayu|external|inactive|all` and `--shell` other
  than `zsh|bash|fish` exit `64`; they were silently accepted (an unknown
  `--source` listed nothing, an unknown `--shell` kept the detected shell).
- `plugin add help` / `plugin add --help` show the add help instead of
  looking up a plugin named `help` (exit `65`).
- `alias` / `const` usage errors and help name the real command
  (`wayu alias add`, `wayu const add`; alias said `wayu aliases`, which is
  not a command), and no longer list argument-less forms such as
  `wayu alias add` (the CLI never prompts).

**Alias names may contain `-`**

- `wayu alias add`, `toml validate` and the TUI now accept a hyphen in an alias
  name after the first character (`onlead-logs`). zsh, bash and fish all accept
  these names and TOML writes them as bare keys. A leading `-` is still refused,
  as are hyphens in constant and function names. Configs that `toml validate`
  used to reject for this reason now pass.

**Hooks**
- A `{path}` / `{name}` / `{value}` placeholder inside double quotes in
  `hooks.conf` is now refused. The shell expanded the value before a nested
  `sh -c "..."` / `eval "..."` re-parsed it, so
  `pre_alias_add = sh -c "echo {value}"` ran code from an alias value. Such a
  hook never runs: any wayu operation that would run hooks exits `78` before
  writing anything and names the offending `hooks.conf` line; `wayu hooks`
  marks it `INVALID`. Write the placeholder unquoted (`echo Adding {path}`,
  wayu quotes the value), inside `'...'` for an inner shell
  (`sh -c 'echo {path}'`), or use `"$WAYU_HOOK_PATH"` / `"$WAYU_HOOK_NAME"` /
  `"$WAYU_HOOK_VALUE"` when you need double quotes. (This replaces the 4.4.x
  advice to use double quotes for direct substitution.)

**Secret values in list views**
- `const list` (text and `--json`, with and without `--full`) now shows
  secret-looking values (names with KEY, TOKEN, SECRET, PASS, API, AUTH, …,
  or token-shaped values) as `********` — both `wayu.toml` `[env]` entries and
  external environment variables. Scripts that read values from
  `const list --json` must add `--reveal`, or use `const get NAME` (unchanged,
  prints the real value). The text table ends with a hint when something was
  masked.
- `toml show` masks secret-looking `[env]` values the same way;
  `toml show --reveal` prints the file verbatim.
- `--reveal` is accepted only by `const` and `toml`; elsewhere it is an
  unknown option (exit `64`).
- TUI constants view: values are masked by default; `v` toggles reveal (the
  footer shows `v Reveal` / `v Hide`) and resets when you leave the view. The
  `/` filter matches the masked text, so typing part of a secret no longer
  finds its row. The detail overlay (Enter) follows the same toggle.

**Plugins (review fixes)**
- `plugin update|enable|disable|priority|get|rm NAME` match the exact plugin
  name (or display name) only, like `const get`. A miss prints nothing on
  stdout, lists up to 5 similar plugin names on stderr and exits `65`; it
  never acts on a fuzzy guess (`plugin disable rig` used to disable `origin`)
  and never prompts. `plugin rm` of an unknown name now exits `65` too (it
  exited `0` "already removed" when nothing was similar).
- `plugin update` no longer resets a checkout whose HEAD has commits that
  were never on the remote: when it cannot fast-forward, the update fails
  (exit `74`) instead of discarding those commits. Push/rebase them or
  reinstall the plugin.
- `plugins.json` `dependencies` entries must be valid plugin names (no
  newline, `/`, leading `-`, empty, `.`/`..`); otherwise any command that
  reads it exits `78`. A newline in one used to inject shell code into the
  generated `plugins.<ext>`.

**build profile**
- The phase breakdown inlines `plugins.<ext>`: it has a row per `[tools]`
  entry (`tool <name> (evalcache)`, `tool nvm (lazy)`, `tool <name>
  (lazy)`) and per plugin (`plugin <name>`) instead of one `Tools` /
  `Plugins` row; core sections keep their names. Rows with no code are
  left out.
- bash: the breakdown now runs too when the shell has `$EPOCHREALTIME`
  (bash 5+); with an older bash it prints a note instead.

**Plugin conflicts**
- A function, alias or exported variable defined by two enabled plugins,
  or by a plugin and your `wayu.toml` (`[aliases]` / `[env]`), is now
  reported: `plugin add` and `plugin enable` print a warning (stderr)
  naming each one, `plugin list` ends with a conflicts section (stderr),
  `plugin list --json` has a `"conflicts": [{"kind", "name", "with"}]`
  array per plugin (`with` is a plugin name or `"wayu.toml"`), and
  `wayu doctor` adds a `plugin conflicts` warning (exit code unchanged).
  Several statements on one line (`export X=1; alias gs=...`) are all
  scanned; the ones after the first were ignored.

**Plugins: installing and loading**
- `plugin add` (and TUI install) refuses a repository with nothing to load
  for the plugin's shell(s): it exits `65`, removes the fresh clone and
  writes nothing (it used to report success while the loader sourced
  nothing). Name the entry file with the new repeatable
  `plugin add <url> --use <file-or-glob>` (matched at the repository root;
  stored as `use` in `plugins.json`). Any other extra argument to
  `plugin add` is now an error (exit `64`).
- `plugin add <url>` records the shells the repository actually has files
  for (`ZSH`, `BASH`, `BOTH`, `FISH` or `ANY`) instead of always `BOTH`, so
  a fish-only plugin added by URL now loads in fish, and a zsh-only one is
  listed as zsh.
- Generated `plugins.<ext>`: only the FIRST existing root entry file is
  sourced (`<name>.plugin.<ext>`, `<name>.<ext>`, `<name>-init.<ext>`,
  `init.<ext>`, `plugin.<ext>`); plugins that ship both
  `<name>.plugin.zsh` and `<name>.zsh` were loaded twice. New entry files:
  `<name>.zsh-theme` (zsh; e.g. powerlevel10k), `<name>.plugin.sh` /
  `<name>.sh` (zsh and bash; e.g. rupa/z), and a top-level `*.zsh-theme`
  when there is no `*.zsh`. Takes effect the next time the loader is
  regenerated (any `plugin` change, `wayu init`).
- Registry: entries whose repository has no shell entry file were removed —
  binary tools (`starship`, `zoxide`, `atuin`, `fzf`, `ripgrep`, `bat`,
  `eza`, `delta`, `direnv`, `mise`, `volta`, `rustup`, `oh-my-posh`,
  `asdf`, `pyenv`, `rbenv`), `autojump`, `fasd`, `git-extras`, `git-flow`,
  plus `zsh-history-enquirer` (pointed at zsh-command-time) and `zsh-dotenv`
  (not a cloneable URL). `plugin add <key>` for them exits `65`; install
  the tool with your package manager and load it from `wayu.toml`
  `[tools]` (e.g. `zoxide = { kind = "evalcache", args = "init zsh" }`).
  Already-installed plugins are unaffected.
- `pure-fish` now installs as `pure-fish` (it shared the name `pure` with
  the zsh prompt). An existing fish `pure` install keeps its name.

**Plugins: network git**
- Clone, fetch and `ls-remote` run without a terminal and with deadlines:
  ssh runs as `ssh -o BatchMode=yes -o ConnectTimeout=10` (unless you set
  `GIT_SSH_COMMAND`, `GIT_SSH` or `core.sshCommand`), so a host-key or
  passphrase prompt fails instead of hanging or garbling the TUI — load the
  key into ssh-agent / accept the host key first. https transfers below
  1000 B/s for 30 s abort (`GIT_HTTP_LOW_SPEED_LIMIT`/`_TIME` override).
  Each command is killed after 10 min (clone/fetch) or 60 s (`plugin
  check`); `WAYU_GIT_TIMEOUT=<seconds>` changes both.
- A failed `plugin add` clone now prints git's error.

**Building from source**
- `./build_it install` installs to `$PREFIX/bin` (default `~/.local/bin`,
  was `/usr/local/bin`), replaces the binary atomically (temp file +
  rename), refuses while Homebrew manages wayu (`--force` to override),
  and warns when another `wayu` shadows the installed one on `PATH`.

**path**
- `path clean` resolves `$VAR`/`${VAR}` from `wayu.toml` `[env]` first, then
  the environment (as the generated init does), and never removes an entry
  whose variable is set in neither. `path dedup` also resolves `[env]`
  variables, so `$TOOLS/bin` and its absolute form count as duplicates.
- `path clean`/`path dedup` exit `78` without changing anything when a dropped
  entry shares its key with a kept one (hand-edited duplicate key in
  `[paths]`); they used to delete both lines.
- `pre_path_remove`/`post_path_remove` hooks get the entry's directory as
  `{path}` when `path rm` is given a key (they got the key).

**[env] values (generated core.zsh / core.bash / core.fish)**
- Only named variables expand: `$NAME`, `${NAME}` and `${NAME...}` /
  `${#NAME}` with a closing `}` (zsh/bash; e.g. `${X:-default}`). Every other
  `$` is now literal: `$1`, `$$`, `$?`, a trailing `$`, `$%`, an unclosed
  `${` (was a syntax error that dropped the whole core file) and zsh flags
  like `${(e)...}` (which evaluated the text, running commands).
- zsh: `$NAME` is emitted as `${NAME}`, so `$HOME:h…` / `$HOME[1]` are no
  longer zsh modifiers/subscripts — zsh now gives the same value as bash.
- fish: `${NAME}`, a bare `$` or `$$` no longer make core.fish fail to parse
  (fish then loaded none of wayu's env, PATH or aliases). `${NAME:-x}` has no
  fish equivalent and is kept literal in fish.
- zsh/bash: `${NAME<op>...}` expands only with `-` `=` `+` `?` (each also
  with a leading `:`), `#`, `%` or `/` (e.g. `${X:-d}`, `${X#pre}`,
  `${X/a/b}`); `${#NAME}` only without an operator. Everything else is now
  literal, e.g. `${X@P}` (bash ≥ 4.4 ran a `$(...)` stored in X),
  `${X[Y]}` / `${X:Y}` (bash evaluated Y arithmetically, running a
  `$(...)` hidden in Y's value), `${X: -2}`, `${X^}` and zsh modifiers such
  as `${HOME:h}` (zsh aborted core.zsh on an unknown modifier).
- fish: `$NAME` followed by a non-ASCII letter (`$HOMEé`) no longer reads as
  the longer variable name `HOMEé`.

**functions/**
- fish now sources `functions/*.fish` (core.fish never loaded them).
- zsh no longer sources `functions/*.bash` / `*.fish`, bash no longer sources
  `functions/*.zsh` / `*.fish` (other shells' files from `wayu function add`
  were parse errors at every startup). Files without those extensions are
  still sourced by zsh and bash.

**Completions (zsh)**
- core.zsh also rebuilds `.zcompdump` when the list of files in the
  completions dir changed, so a completion added in the same second as the
  dump is no longer missed. The list seen at the last rebuild is kept in
  `${ZDOTDIR:-$HOME}/.zcompdump.wayu`; the first shell after upgrading
  rebuilds the dump once.

**Completions for wayu itself (zsh, bash, fish)**
- The first argument of `path|alias|const rm|get`, `plugin
  rm|get|enable|disable|priority|update`, `function add|edit|rm` and
  `completions rm` completes existing entries (paths as written in
  `wayu.toml`, alias/constant/plugin/function/completion names). The
  scripts list them by running the hidden `wayu completions names <kind>`
  (`$_WAYU_BIN`, else `wayu` on `PATH`) at TAB time. Re-run
  `wayu completions generate` to update installed scripts.
- fish: action words are offered only right after the command
  (`wayu alias rm <TAB>` no longer offers `add`, `list`, …); flags still
  complete anywhere.

**migrate --schema**
- Values it can't convert exactly (multi-line `"""` strings, arrays, inline
  tables) in the rewritten sections are listed as `wayu.toml:N`; nothing is
  written and it exits `65`. They used to be dropped silently (an alias with
  a `"""` command became `""`). A section header with a trailing comment
  (`[aliases] # mine`) is now recognised.
- Waits for other wayu commands (config lock) before rewriting wayu.toml.
- `[[paths]]` / `[[aliases]]` / `[[constants]]` fields the modern schema
  has no place for (legacy `description`, `export`, `secret`, …) are listed
  on stderr as `wayu.toml:N` warnings; they used to vanish silently. The
  migration still runs (exit `0`).

**doctor**
- A relative `[paths]` entry (`./node_modules/.bin`) is no longer reported
  as missing or removed by `doctor --fix`: it is counted with the entries
  that "use unset variables or relative paths (left alone)".
- `doctor --fix` exits `78` and changes nothing when a key it would drop is
  repeated in `[paths]` (`a = "/x"` twice); it used to delete every line of
  that key, the kept entry included.
- bash: new warning `bash PROMPT_COMMAND` when a bash startup file replaces
  `PROMPT_COMMAND` after the line that loads wayu (it dropped the
  `_wayu_paths_sync` hook, so open shells missed `wayu path add/rm`). Shown
  only when such a line exists; exit status unchanged (warnings never exit
  `78`).
- `shell configuration` / `Sync status`: only a line that runs `source`,
  `.` or `eval` counts as loading wayu; a line that just mentions the file
  (`alias e='vim ~/.config/wayu/init.zsh'`) no longer passes.
- `Sync status` now compares the `[paths]` entries with the `$PATH` doctor
  runs in: OK when all are present, INFO "N of M PATH entries not in this
  shell's $PATH" otherwise (it used to claim "All wayu entries are loaded"
  from the rc text alone).
- A `[paths]` entry using an environment variable whose value is relative
  (`$FOO/bin` with `FOO=rel`) counts as unresolved, never missing.
- `backups`: a missing backup directory (fresh install) is INFO "No backups
  yet", not a warning.
- Dependencies: checks `git` plus the configured shell (`zsh`, `bash` or
  `fish`) instead of always `zsh`.

**Backups**
- `wayu backup restore` waits for other wayu commands (config lock) instead
  of racing them; a concurrent edit can no longer overwrite the restore.
- Backup times are UTC and now say so: `backup list` prints
  `2026-11-07 14:35:37 UTC`; `backup list --json` `timestamp` is ISO-8601
  (`2026-11-07T14:35:37Z`, was `2026-11-07 14:35:37`).
- `backup list` and `backup rm` (no type) cover every file in the backup
  directory, not only wayu.toml: the rc file `wayu init` edits, `init.zsh`
  (`--optimize`), `plugins.json`, ... Each `--json` group's `file` is the
  wayu file name or the rc path (`~/.config/zsh/.zshrc`). `backup restore`
  still restores wayu.toml only; copy other backups back by hand.
- Backups of files outside wayu's directories are named after their path
  relative to `$HOME` with `/` as `%` (`.config%zsh%.zshrc.backup.*`), so
  `~/.zshrc` and `$ZDOTDIR/.zshrc` keep separate histories (`~/.zshrc`
  keeps the old `.zshrc.backup.*` name).
- Backups were silently skipped when the config path contained `.backup.`
  (`HOME=/x/my.backup.d`); only the file name is checked now.
- `backup restore` prunes to the 5 newest backups after its pre-restore
  snapshot (never the backup it restored), so repeated restores no longer
  grow the directory.
- `backup restore <type> N`: N must be decimal digits; `0x1` / `+1` are
  treated as file names (exit `65`), not #1.

- `wayu backup list|restore|rm` work while `wayu.toml` still uses the
  obsolete `[[paths]]` schema (they exited `78`).
- `backup restore` refuses a `wayu.toml` backup that uses the obsolete
  `[[paths]]` / `[[aliases]]` / `[[constants]]` schema (exit `74`, file
  unchanged); restoring one made every other command exit `78`, including
  the undo `backup restore <type> 1`. Copy such a backup over `wayu.toml`
  by hand and run `wayu migrate --schema`.

**init.<ext> from wayu ≤ 3.9**
- An unmodified `init.zsh` written by wayu 3.9 or older is now recognised
  and updated to the current template (old file backed up), like newer
  ones. It used to be kept with a "has local edits" warning, so after
  `wayu migrate` it still sourced the emptied legacy files and the shell
  got no PATH, aliases or constants.

**TUI**
- Adding or deleting an entry while `wayu.toml` uses the obsolete
  `[[paths]]` schema (e.g. replaced by an old wayu after the TUI started)
  is refused with "run `wayu migrate --schema`"; it used to append a
  `[paths]` table to the old-schema file.
- The Backups view lists `wayu.toml` backups and Settings counts them; both
  only looked at the pre-3.10 `path`/`aliases`/`constants` files, so they
  showed none.
- Adding in the TUI follows `wayu path add` / `alias add` / `const add`:
  PATH input `name=path` sets the `[paths]` key (it was stored as a path
  relative to the TUI's directory), and the path must resolve and exist
  (relative paths resolve against the directory wayu was started in);
  otherwise the form shows the CLI's reason. Adding an alias or constant
  that already exists asks "REPLACE …?" first. Notifications say
  `Added` / `Updated` / `Already present, nothing changed` (a duplicate
  PATH said `Added`).
- `--dry-run`: a `DRY RUN` badge sits on the top border; previews read
  `[dry-run] would add alias: x = "…"` / `[dry-run] would remove …` (were
  `Dry run: would …`). Plugin enable/disable/install no longer write
  `plugins.json` under `--dry-run` (install recorded a plugin that was never
  cloned).
- Keys: `r` / Ctrl+R / F5 reload every view; views also reload by
  themselves when `wayu.toml`, `plugins.json`, `hooks.conf` or the backup
  directory change on disk. `e` edits the selected entry (a PATH keeps its
  key and position; a renamed alias/constant replaces the old name; secret
  values must be revealed with `v` first). `u` restores the newest
  `wayu.toml` backup after a confirmation. Text fields edit at a cursor
  (←/→, Home/End, Ctrl+A/E/U/K/W, Delete) and show the end of long input.
- Plugins: Enter shows details on both tabs (on Registry it used to install
  at once); `i` installs after a confirmation; on Installed, space toggles
  enabled, `e` enables, `x` disables, and `d` (which disabled) only shows
  the `wayu plugin rm` command.
- Backups view lists every backup group (`plugins.json`, the rc file, init
  files…, newest first). Enter on a `wayu.toml` backup restores it after a
  confirmation (like `wayu backup restore`); `c` asks, then prunes every
  group to the newest 5 (it targeted pre-3.10 files and removed nothing).
- Long operations show a progress frame and can be cancelled with Esc /
  Ctrl+C: the alias view's `$SHELL -i -c alias` (now given up after 3 s,
  listing no external aliases), plugin clones, and hooks (in the TUI a hook
  is stopped after 30 s).
- Hooks view lists every hook event with its command; space disables a hook
  by commenting its `hooks.conf` line as `# disabled: <line>` (and enables
  it again), `t` runs it once with sample values and shows its output.
- Settings view: Enter toggles dry-run or colors for the session (nothing
  is saved); also shows the editor and the backups kept per file.
- Below 40x12 the TUI shows "Terminal too small" instead of an empty
  layout. It quits when its terminal input is closed (EOF) instead of
  spinning.

**wayu.toml parsing (one parser for every command)**
- `toml validate`, `doctor`, `backup restore`, `migrate --schema`, the TUI,
  `alias/const/path list`, the shell generator and the in-place editor now
  share one TOML parser, so they agree on every file.
- Now accepted as valid (were "Failed to parse" for `toml validate`, the TUI
  and doctor): a UTF-8 BOM, arrays spanning several lines (e.g. `[settings]
  autosuggestions_accept_keys`), quoted keys (`".." = "cd .."`), dotted keys,
  floats and dates.
- Now rejected by `toml validate` / doctor / `backup restore`: a key defined
  twice in one table, a table defined twice, integers with leading zeros.
  Other commands keep working on such a file as before.
- `toml validate` and doctor name the offending line: `Failed to parse
  <file>: line 5: invalid value "ls" (strings must be quoted)`.
- Quoted keys are decoded everywhere: `"q\"k" = …` is the alias `q"k` in
  `alias list` (was listed with its quotes) and `alias rm ..` finds
  `".." = …` (said "not found").
- TUI: [paths] are shown in file order (= PATH priority; were sorted by key),
  and entries of a file with a syntax error are shown like `alias list`
  shows them (the view was empty).
- [paths]/[aliases]/[env]: arrays and inline tables are skipped (the raw
  text, e.g. `["a"]`, used to be exported). Integers are read as their value
  (`N = 1_000` → `1000`). A key containing a dot written bare (`g.st = …`,
  which wayu itself wrote for such alias names) is still the name `g.st`.
- wayu writes keys that need it quoted (`"g.st" = "git status"`) and
  escapes control characters in values (`\u001B`), so everything it writes is
  valid TOML.
- `migrate --schema` lists (instead of copying verbatim) lines that are not
  valid TOML, such as an unquoted value.
- An edit refused because a table holds a broken multi-line value now says
  why (`wayu.toml line N: unterminated array (missing ']') in [env] …`).
- `[shell] type` is written lowercase (`"zsh"`, `"bash"`, `"fish"`; was
  `"ZSH"`, `"Bash"`, `"Fish"`, `"Unknown"`) by `wayu init`, `migrate --from
  X --to Y` and any command that creates a missing `wayu.toml`.
  `wayu config edit` on a missing file creates the same scaffold (it wrote
  `[settings] shell = "zsh"` plus commented examples), and so does legacy
  `wayu migrate` (it started the file with a comment line and no `[shell]`).
- `toml validate` now checks `[shell] type` (case-insensitive); it only saw
  a top-level `shell = …` key before. A value other than zsh/bash/fish
  — including `"Unknown"`, written when no shell was detected — fails with
  `Invalid shell: unknown (must be zsh, bash, or fish)`.

**WAYU_CONFIG_DIR / WAYU_DATA_DIR**
- `WAYU_DATA_DIR` is honoured when `WAYU_CONFIG_DIR` is also set (it was
  ignored: data always went to the config dir). Data dir = `WAYU_DATA_DIR`,
  else the config dir.
- `init.zsh` / `init.bash` / `init.fish` find their files next to
  themselves instead of in `~/.config/wayu`, so the rc line works without
  exporting the overrides to the shell (it used to fail with "no such file"
  and load no PATH/aliases). The config dir falls back to the init file's dir
  when that holds `wayu.toml`. An unmodified init file is updated on the next
  regeneration (backup first).
- When the dirs differ from the defaults, `core.<ext>` exports
  `WAYU_CONFIG_DIR` / `WAYU_DATA_DIR`, so `wayu` commands typed in that shell
  (and the path-sync background `wayu build`) use the same dirs.

**[tools] evalcache**
- The cache is regenerated when the tool's binary changes, not only when it
  gets newer: zsh compares resolved path + size + mtime + inode, bash the
  path, the exact mtime and the inode/resolved target. Cache files now start
  with a `# wayu-evalcache:` line; old caches are rebuilt once. bash also
  keeps a `<cache>.bin` link next to each cache file.
- The tool is looked up in `PATH` only and run as `command <tool>` (a
  function or alias of that name is no longer called).
- New `wayu build clean` deletes the cache
  (`${XDG_CACHE_HOME:-~/.cache}/wayu/evalcache`), for init output that
  depends on config or environment.
- `args` is split into words like the shell does (quotes honoured) and each
  word is quoted in the generated call; `$NAME` / `${NAME...}` and a leading
  `~/` still expand, `{a,b}` no longer brace-expands. Args containing a
  newline, `;` `&` `|` `<` `>` `(` `)`, `$(...)` / backticks or glob
  characters (`*` `?` `[`) are refused: `wayu build` exits `78` naming the
  tool, other regenerations skip the tool with a warning on stderr.

**Prompt (zsh, `[prompt] enabled = true`)**
- Default modules have separators like starship:
  `{username}{dir}{git_branch}{character} ` with `[$user](white bold) in `,
  `[$dir](cyan bold) ` and `on [$branch](magenta bold) `. Custom `format` /
  module formats are unchanged.
- The user name shows only over SSH or as root unless `[prompt.username]
  show_always = true` (the setting was ignored).
- vi mode is opt-in: the prompt no longer switches the line editor to the
  vi keymap or sets `KEYTIMEOUT`. **vi users: add `vi_mode = true` under
  `[prompt]`** to get `bindkey -v`, `KEYTIMEOUT=1` (no longer exported to
  child processes) and the mode indicator (`[prompt.interactive]
  vi_mode_indicator = false` keeps the keymap without the indicator).
  Without vi mode the `{character}` module shows success/error by exit
  status.
- `zle-line-init` / `zle-keymap-select` are chained: a widget already
  installed under that name (yours, a plugin's, another prompt's) is kept as
  `_wayu_prev_<name>` and runs first; it used to be replaced.
- The git branch is read without running git (walks up to `.git`, reads
  `HEAD`; worktrees/submodules and `$GIT_DIR` included; detached HEAD shows
  the first 7 characters of the commit id) — two `git` processes per prompt
  are gone. The dirty count is still fetched asynchronously.
- The prompt toggle is off by default; enable it with `[prompt.interactive]
  toggle_enabled = true`. It is bound after the vi keymap is set up, in
  `viins` + `vicmd` with `vi_mode = true`, else in `emacs`; it used to land
  in a keymap that `bindkey -v` then replaced, or steal emacs `^P`.
- Prompt code runs `command git` / `awk` / `sed` / …, so user aliases or
  functions with those names no longer change or break it.

**Generated init: one fast file (zsh/bash)**
- `core.<ext>` is now the only generated file `init.<ext>` loads: what used
  to be `lazy.<ext>` ([tools] lazy loaders, `tools.<ext>`, `extra.<ext>`),
  `login.<ext>` (login-only tools, now inside `if [[ -o login ]]` /
  `shopt -q login_shell`) and `helpers.<ext>` (evalcache, zsh-defer) is
  inlined, and the startup PATH apply no longer reads `path_sync.<ext>`
  (the prompt hook still does). wayu deletes old `lazy` / `login` /
  `helpers.<ext>` files (and their `.zwc`) when it regenerates; anything
  that sourced them directly should source `init.<ext>` instead. Load order
  is unchanged.
- zsh: `compinit` runs only in interactive shells (completion is a
  line-editor feature, and compinit was most of the cost of sourcing init in
  scripts and `zsh -c`); in other shells a no-op `compdef` is defined if
  none exists, so plugins calling it stay quiet. `.zcompdump` is also
  zcompiled (`.zcompdump.zwc`, in the background) — compinit loads it
  ~40% faster. The compiled file is installed only if the dump did not
  change while compiling, so a shell rebuilding the dump at the same time
  can't leave a stale `.zwc` that hides newly added completions.
- zsh: the native prompt is set up in interactive shells only.
- bash: the PATH apply no longer uses here-strings (a temp file each in
  bash 3.2) and compares in the C locale; the separate dedup pass is gone
  (the apply already leaves PATH without duplicates).
- [tools] evalcache (zsh) finds the tool by walking `$path` instead of
  `${commands[...]}`, which hashed every PATH directory (~2 ms).
- Startup, 20 [paths] / 60 [aliases] / 20 [env] (`tests/benchmark/startup.sh`,
  macOS, hyperfine): `zsh -f -c 'source init.zsh'` 22.8 → 9.3 ms (empty zsh
  ~3.5 ms; turbo.zsh was 8.4 ms), interactive (`zsh -fi`, with compinit)
  22.3 → 16.0 ms; bash 9.3 → ~5 ms (turbo.bash was 3.1 ms).
- `wayu build` / `build eval` list `core.<ext>` and `path_sync.<ext>` only.

**wayu export**
- `turbo.<ext>` now has exactly `core.<ext>`'s content — every feature
  ([tools] loaders, prompt, login tools, live PATH sync, completions with
  compinit) at the same speed — and wayu rewrites it whenever it regenerates
  core (any `path/alias/const` change, TUI edit, `wayu build`), so it no
  longer goes stale. Sourcing `init.<ext>` is equivalent; turbo stays for rc
  files that already use it. `wayu export --turbo` output text changed.
- `wayu export --eval` expands `[paths]` values in the shell (like core):
  `[paths] b = "$FZG/bin"` with `[env] FZG = "~/g"` now works (it was
  dropped), an entry whose variable is unset is skipped, and entries are
  checked with `[ -d ]` when eval'd (not when wayu runs). Duplicates are
  dropped. The PATH part is now a short loop instead of one `export PATH=`.
- `wayu build` no longer prints the turbo export report when turbo.<ext>
  exists (it is refreshed silently with core).

**fish (core.fish)**
- `[tools]` now load in fish. evalcache entries run `<tool> <args> |
  source`, cached under `~/.cache/wayu/evalcache/fish__*` (regenerated when
  the binary's path or mtime changes; needs fish 3.5+, older fish runs the
  tool uncached). Args are retargeted: a word `zsh` or `bash` becomes
  `fish` and `--zsh` / `--bash` becomes `--fish`, so `args = "init zsh"`
  runs `<tool> init fish`. `eager`, deferred (after plugins) and
  `login_only` (`status is-login`) work as in zsh/bash. A `lazy` entry
  needs a fish `init_script` (`*.fish`); `nvm` / `conda` recipes have no
  fish version and are skipped with a comment.
- `functions/*.fish` load (they did only on the legacy path).
- `[paths]` dirs move to the front of PATH in `[paths]` order, like
  `fish_add_path -gpm`: a dir already on PATH (e.g. `/usr/local/bin`) now
  gets wayu's priority instead of keeping its old place. Dirs wayu did not
  add are never removed.
- Live PATH sync: `wayu path add/rm` and hand edits of `[paths]` reach open
  fish shells at the next prompt (a `fish_prompt` event handler re-reads the
  new `path_sync.fish` when the list changed), as in zsh/bash.
- Re-sourcing `init.fish` no longer adds the completions dir to
  `fish_complete_path` again.
- `[aliases]` are defined last (after plugins and tools), as in zsh/bash.
- `init.fish` sources `tools.fish` before `extra.fish` (was the reverse).
  An untouched `init.fish` is updated automatically.

**zcompile**
- A background compile interrupted by a signal removes its temp digest, and
  temp digests (`<file>.<pid>.tmp.zwc`) older than a minute are swept before
  compiling; the compile also runs in its own session, so closing the
  terminal no longer kills it halfway (stray `core.zsh.<pid>.tmp.zwc` files
  were left in the data dir).
- Generated zsh files are recompiled in the background after every change
  (`wayu path/alias/const add`, TUI, …), not only by `wayu init` / `build`,
  so the bytecode speedup no longer disappears after the first edit.
- `wayu_compile` (now defined in core.zsh) uses the data dir the file was
  generated for, and compiles core, plugins and turbo.
- `wayu build profile` works when the data dir path contains spaces.

**Colors**
- Output is plain (no ANSI escape codes) when stdout is not a terminal:
  `wayu path list | grep x`, `$(wayu ...)`, logs and CI get plain text.
  Set `FORCE_COLOR=1` (or `CLICOLOR_FORCE=1`) to keep colors in a pipe.
  Errors/warnings on stderr are colored only when stderr is a terminal.
- `NO_COLOR=1` and `--no-color` now remove every escape code (tables,
  help, errors, doctor, backup list, …); some used to remain. They win over
  `FORCE_COLOR`.

**Errors and warnings**
- `ERROR: …` and `⚠ …` messages go to stderr (they were on stdout), so
  `2>/dev/null` silences them and `wayu … --json | jq` never sees them.
- A failed read of a file reports one error, not two (the extra
  `ERROR: Could not read …` line is gone).
- Before `wayu init`, `path list|get|rm|clean|dedup` and `path add` of an
  existing directory exit `78` with the "not initialized" message, like
  `alias`/`const` (they exited `66` with "File not found").
- `wayu export help` / `export list` work without a wayu config.

**--json**
- `alias list --json`, `const list --json` and `plugin list --json` print
  an empty JSON list (`{"aliases": []}`, …) when there is nothing to list;
  they printed `ℹ No … found`.
- `plugin list --json` escapes every string (a quote or backslash in a
  path broke the document).
- `path list --json --source external` (and `--full`) include the external
  `$PATH` entries the table shows (`"source": "external"`); they were
  dropped.
- `search QUERY --json` prints `{"query": …, "results": [{"type", "name",
  "value", "match", "field", "score"}], "count": N}`; it ignored `--json`.
- `--json` on a command/action without JSON output (`path add`,
  `const get`, `hooks`, `toml show`, …) exits `64` and names the commands
  that support it; it used to be ignored. Supported: `path|alias|const|
  backup|plugin list`, `search`, `doctor` (and any `help`).

**Commands and actions**
- Command names, action words, per-command flags and `--json` support
  come from one table (also used by completions and `wayu help`). An
  action word a command doesn't have exits `64` with that command's help:
  e.g. `alias check` (silently did nothing, exit `0`), `alias clean`
  (exit `1`), `backup clean|add|get`, `path enable`.
- `wayu help` lists every command (it missed `build` and `export`) and a
  COMMAND FLAGS section; `--json` and `--no-color` are listed under FLAGS.
- Completions offer each command's flags and `--json` where supported, and
  `export check`.

**Tables and pickers**
- List tables written to a pipe or file (`wayu path list | cat`) are no
  longer fitted to 80 columns: values are printed whole. An exported
  `COLUMNS` still sets the width.
- The interactive picker (TUI remove, completions) keeps every character of
  a paste or fast typing (only the first one was used), ignores unknown
  escape sequences instead of filtering on their bytes, and a lone `Esc`
  cancels like `Ctrl+C`. `kill -INT` / `kill -QUIT` restore the terminal.

**TUI terminal handling**
- Keys: `Esc` followed by a key within 100ms is now Alt+key (what
  terminals send for Meta/Option chords) and does nothing; it used to be
  "Escape, then the key", so Alt+d in the filter cancelled it and opened a
  delete confirmation. A lone `Esc` therefore takes effect after 100ms
  (was 25ms), which also keeps arrow keys split by a slow ssh link from
  acting as `Esc`. `ESCDELAY` (milliseconds, as in ncurses) changes the
  window.
- Paste: bracketed paste is enabled while the TUI runs. A paste goes into
  the focused text field (add form, filter) as text — newlines dropped,
  tabs as spaces — and is ignored anywhere else; pasted newlines and
  letters no longer submit forms or run actions. In terminals without
  bracketed paste, keys typed ahead of a delete confirmation or after a
  submitted form are discarded, so the rest of a pasted line can't answer
  the dialog.
- `Ctrl+Z` suspends the TUI (and `kill -TSTP` restores the terminal before
  stopping); `fg` resumes and repaints. `Ctrl+Z` used to be ignored.
- Colors: list text uses the terminal's default foreground instead of a
  fixed light gray. On a light background — `WAYU_THEME=light`, a light
  `COLORFGBG`, or the terminal's answer to an OSC 11 query at startup
  (`WAYU_THEME=dark` skips the query) — dividers, orange/amber, green and
  blue accents use darker variants. In 16-color terminals the accent is
  bright magenta (was red, like errors) and dividers gray (were black). The
  hidden cursor is parked on the selected row for screen readers.
- Width: combining accents, emoji variation selectors (VS16) and ZWJ
  sequences take no column of their own, and text-style symbols such as
  `➜ ✔ ★ ❤ ⛰` count as one column (they counted two), using the same
  Unicode tables as terminals. Rows with such characters no longer shift or
  leave stray glyphs in the TUI, and CLI tables containing them line up
  differently. In the TUI a VS16 or ZWJ is dropped, so `❤️` is drawn as `❤`
  and a ZWJ family emoji as its separate emoji.
- If the TUI dies (a crash or a fatal error in shared code), what it wrote
  to stderr — the runtime's bounds-check location, the error before the
  exit — is printed after the terminal is restored; it used to be wiped
  with the alternate screen. An unreadable `wayu.toml` while adding or
  removing an entry is reported in the TUI instead of exiting with the
  terminal left raw.

**Editor (`function add/edit`, `config edit|extend`, `hooks edit`)**
- `$EDITOR` / `$VISUAL` may carry arguments (`code --wait`, `subl -w`): it
  runs as `sh -c '$EDITOR "$1"'`. It used to be looked up as one program
  name and silently fail.
- An editor that can't start or exits non-zero makes wayu exit `1` with
  `ERROR: Editor '…' exited with status N` (it exited `0` and printed
  "Reload your shell…"); `config edit` then skips regenerating the init.
- With neither variable set, every command opens `vi` (`function` and
  `config` used `nvim`).

**Templates**
- `template apply` never overwrites what you have: a `[paths]` directory
  already listed, an alias or `[env]` name already in wayu.toml, or a
  constant already set in the environment wayu runs in is kept and shown as
  `Keeping …`. (It used to replace e.g. `EDITOR = "nvim"` with
  `code --wait`.) The summary reads "N added, M kept".
- `--dry-run template apply …` prints `Would add …` / `Keeping …` and
  "Nothing was written"; it used to print "… template applied!".
- The `developer` template no longer adds `code = "code ."` (it shadowed
  the `code` binary).
- `wayu init --template <name>` (or `--template=<name>`) works: init, then
  apply the template. An unknown name exits `65` and a missing one `64`,
  before anything is written; any other argument to `init` exits `64`.

**config scan --fix**
- Aborts (exit `74`) when extra.<ext> exists but can't be backed up or
  read; it used to write anyway.
- Blocks already in extra.<ext> are not appended again, so re-running it no
  longer duplicates PATH prepends and evals; with nothing new it prints
  "All N blocks are already in …" and writes nothing.

## 5.0.0

**doctor**
- `doctor --json` (and `--json doctor`) prints JSON; `--json --fix` exits `64`.
- `doctor` exits `78` when any check reports an error (also with `--json`).
- `doctor --fix` requires `--yes` (exit `64` otherwise); `--dry-run --fix`
  previews. It no longer symlinks `./wayu` into `/usr/local/bin` or generates
  turbo files, and never removes a `[paths]` entry that uses an unset variable.
- `doctor --optimize` is removed (exit `64`); use `wayu build` / `wayu export`.
- Startup detection covers `~/.zshenv`, `$ZDOTDIR`, `.zprofile`, `.zlogin`,
  `.bash_profile`, `.bash_login`, `.profile`, fish `conf.d/` and
  `eval "$(wayu build eval)"`. `wayu init` writes `$ZDOTDIR/.zshrc` when
  `ZDOTDIR` is set.

**migrate**
- Legacy import parses shell quoting exactly (single/double quotes, `$'..'`,
  escapes, `export A=1 B=2`, `typeset -x`, fish `set -gx`/`alias`). Lines it
  can't convert exactly (functions, conditionals, multi-line values, command
  substitution, …) are listed with `file:line`; then nothing is imported or
  archived and it exits `65`. Files are archived only after a full import.
- `migrate --from X --to Y` no longer translates generated files line by
  line: it requires `wayu.toml` (exit `78` otherwise), sets `[shell] type` and
  regenerates the target shell's files from `wayu.toml`.

**Prompt (zsh)**
- The native wayu prompt is now opt-in. It is generated only when
  `wayu.toml` has `enabled = true` under `[prompt]`; without it wayu no longer
  sets `PROMPT`/`RPROMPT`, `setopt promptsubst`, the vi keymap
  (`bindkey -v`), `KEYTIMEOUT=1`, the `zle-line-init`/`zle-keymap-select`
  widgets or its git/async precmd hooks. To keep the previous prompt, add:

  ```toml
  [prompt]
  enabled = true
  ```

- `[prompt]` text (format, character symbols, `[prompt.contexts]` formats,
  `rprompt_format`) is literal: `$(...)`, backticks, `$VAR` and quotes are
  printed as typed instead of being executed or breaking `core.zsh`. Prompt
  `%` escapes (`%n`, `%~`, …) and the module variables (`$dir`, `$user`,
  `$branch`, `$version`, `{git_pending}`, …) still work.
- `toggle_key` and `[settings] autosuggestions_accept_keys` are emitted as
  single-quoted `bindkey` arguments; a key containing `'` no longer breaks
  (or injects code into) the generated file.
- The async right prompt keeps its data in a private `mktemp -d` directory
  (mode `0700`, removed when the shell exits) instead of
  `${TMPDIR:-/tmp}/.wayu_async_<pid>`.

**Watcher**
- `wayu watch` no longer grows in memory while idle, and removes its
  `watcher.pid` when stopped with Ctrl+C / `SIGTERM` / `SIGHUP`.

**Plugins**
- `plugin rm` on a plugin dir that is a symlink removes only the link; the
  link target (e.g. your working copy) is never touched. A plugin dir that
  resolves outside `plugins/` is not deleted (warning; the entry is still
  removed from `plugins.json`).
- `plugins.json` is validated on load. Any command that reads it exits `78`
  naming the bad entry when a `url` is not https://, ssh://, `git@host:` or
  file://, starts with `-` or contains whitespace/control characters; when a
  `name`, `git.branch`/`tag`/`commit`/`pinned_ref` or `installed_path` starts
  with `-` (or has control characters); or when `shell`, `template`,
  `source_type` or `git.ref_type` holds an unknown value. Enum values are
  matched case-insensitively (`"shell": "bash"` used to load as zsh) and
  `plugins.json` now stores them as names (`"shell": "ZSH"`) instead of numbers;
  old files still load and older wayu versions read the new ones.
- Plaintext `http://` and `git://` plugin URLs are refused (`plugin add` exits
  `65`). `ssh://` and `file://` URLs are now accepted by `plugin add`.
- `plugin add <name-or-url>@<commit>` (7–40 hex digits) installs at that commit
  and pins it; pinned plugins are skipped by `plugin update`, and `plugin
  check` fails if the checkout has moved off the pinned commit.
- `plugin check` exits `74` and prints "N plugin(s) could not be checked"
  instead of "All plugins are up to date!" when any remote could not be read.
  It compares against `refs/heads/<branch>` exactly, so branches like
  `release/main` or a tag named `main` no longer cause false "update
  available" reports.
- `plugin update` fetches and fast-forwards; when upstream rewrote history
  (force-push) a clean checkout is reset to the remote branch. A checkout with
  local modifications, or a symlinked plugin dir, is never reset — the update
  fails with git's error message, which is now shown. Output shows the
  `old → new` commit for each plugin.
- `--dry-run plugin update` prints "Would update …" and no longer claims
  plugins were updated.

**Generated shell code**
- `[aliases]` are defined at the end of `core.<ext>`, after plugins, lazy
  tools, `tools.<ext>` and `extra.<ext>`. Functions in those files can no
  longer rely on wayu aliases being expanded inside their bodies; an alias
  named like a wrapper (`npm`, `conda`, a `lazy` hook command) no longer
  breaks the tool loaders.
- zsh init works under `NO_BARE_GLOB_QUAL`, `KSH_ARRAYS` and `NO_GLOB`, and
  with aliases for `ls`/`rm`/`node`/… defined before wayu is sourced.
- The user-function loop variable `f` is no longer left set in the shell.

**nvm (`[tools] nvm = { kind = "nvm" }`)**
- The default node is resolved like nvm does: aliases are followed
  (`lts/iron`, `lts/*`, `v20.18.0` with a leading `v`), the highest matching
  install wins (`20` → newest 20.x, not the lexicographically last), and a
  partial version matches whole components (`20.1` → 20.1.x only). Defaults
  that previously put no node (or an older one) on PATH now pick a different
  version. `.nvmrc` / `.node-version` (zsh) use the same rules.

**Completions**
- zsh: when `~/.config/wayu/completions` changed after `~/.zcompdump` was
  written (e.g. `wayu completions add`), the dump (and its `.zwc`) is
  deleted and rebuilt with `compinit -u`; otherwise `compinit -C` as before.
- bash: `completions/*.bash` is sourced too, so `wayu completions generate`
  (which writes `wayu.bash`) enables wayu's own bash completion.
- wayu's own zsh/bash/fish completions cover every command (`doctor`,
  `template`, `hooks`, `reload`, `build`, `function`, aliases like `const`,
  `fn`, `watch`) and are generated from one table.

**init.<ext>**
- `init.<ext>` is only updated when it is an unmodified copy of a template an
  earlier wayu wrote; the old file is backed up first. A file you edited is
  left alone and wayu prints a warning on stderr (once per edit when stderr
  is a terminal). To adopt the new template, move it aside and run
  `wayu init`.

**Flags**
- Unknown options are an error: `wayu path add DIR --dryrun` (typo) exits `64`
  and writes nothing instead of performing the add. Each command accepts the
  global flags plus its own (`doctor --fix`, `plugin update --all`,
  `migrate --from/--to/--schema`, `export --eval/--turbo/--check`, …). A value
  that starts with `-` goes after `--` (`wayu path rm -- -odd`); the first
  value word of `alias add` / `const add` (`const add OFFSET -5`) and negative
  numbers (`plugin priority foo -1`) are still taken as values.
- A global long flag at the very end of `alias add` / `const add`
  (`--dry-run`, `--yes`, `--json`, `--no-color`) is now a flag, not part of
  the value: `wayu alias add x y --dry-run` previews instead of storing
  `y --dry-run`. To keep it in the value, put `--` before the value:
  `wayu alias add hd -- helm install --dry-run`. A trailing `-n` / `-y`
  still belongs to the value (`grep -n`) but prints a warning on stderr.

**Hooks**
- A `{path}` / `{name}` / `{value}` placeholder inside single quotes in
  `hooks.conf` is no longer substituted by wayu: it becomes
  `"$WAYU_HOOK_PATH"` (etc.) for an inner shell to expand. This closes a
  command injection through `sh -c '... {path}'`, `ssh`, `eval`. A plain
  `echo 'Adding {path}'` now logs the literal reference — use double quotes
  (`echo "Adding {path}"`) for direct substitution. `wayu hooks` flags such
  placeholders.
- `pre_*` hooks run only when the operation will really write: not for
  invalid names, missing entries on remove, or duplicate path adds.

**Backups**
- Every write now keeps only the newest 5 backups per file (previously only
  `path clean/dedup` pruned, so the backup dir grew without bound).
- A command takes at most one backup per file (the state before it ran):
  `migrate`, `template apply`, `doctor --fix` no longer leave one backup per
  entry. The TUI still backs up every change.
- `wayu backup restore <type> [N|file] --yes` restores backup `#N` from
  `wayu backup list` (or that file). The snapshot taken before a restore is
  marked `[pre-restore]`, and a restore without `N` skips those, so repeating
  it no longer flips between the last two states; undo a restore with
  `wayu backup restore <type> 1 --yes`. `backup list --json` entries gain
  `index` and `pre_restore`.

**export / build**
- `wayu export --eval`, `--check` and `--turbo` now do what the help says
  (they all used to regenerate the turbo file and print decorated output,
  so `eval "$(wayu export --eval)"` broke the shell). `--check` exits `78`
  when the turbo file is missing or older than `wayu.toml`.
- `wayu export list` shows the formats instead of writing the turbo file; an
  unknown `export` mode or `build` target exits `64`.
- `wayu export` refuses fish (exit `64`): its output is sh syntax. `wayu
  build` no longer refreshes a turbo file for fish.
- Turbo/eval output does not include `[tools]` lazy loaders, the prompt,
  login hooks or live PATH sync; the help now says so (it used to promise a
  drop-in faster replacement). `wayu build` help no longer claims
  SIMD/threaded/GPU optimisation.

## 4.4.4

**Lookups and output**
- `wayu const|alias|path get NAME` matches the exact name only (case-sensitive).
  A miss prints nothing on stdout, lists up to 5 similar *names* (never values)
  on stderr and exits `65`. The interactive fuzzy picker and the
  `WAYU_FFF_AUTO_FALLBACK` / `WAYU_FFF_INTERACTIVE` toggles are gone.
- Secret-looking values (names with KEY, TOKEN, SECRET, PASS, API, AUTH, …, or
  token-shaped values) are shown as `********` in `--dry-run`, `search`,
  `export --dry-run` and migrate dry-runs. `const get` and `const list` still
  print real values.
- `--dry-run` on alias/const/path changes shows only the keys that change
  (`+` / `~` / `-`), not the whole `wayu.toml`.

**Files and permissions**
- Backups and generated files (`core`, `lazy`, `login`, `helpers`) are `0600`,
  the backup dir `0700`; older backups are tightened on the next backup. A new
  `wayu.toml` is created `0600`; an existing one keeps its mode.
- All writes are atomic (temp file + rename) and serialized across processes
  by `~/.config/wayu/.wayu.lock`; concurrent `wayu` commands queue instead of
  losing entries.
- A `wayu.toml` table holding an unterminated multi-line value makes edits
  fail with exit `65` and writes nothing.

**PATH**
- `[paths]` is never re-sorted: file order is PATH priority. `path add`
  appends (lowest wayu priority, still ahead of system dirs).
- Entries containing `:` or a newline are rejected (exit `65`); such
  hand-edited entries are skipped with a warning.
- The `wayu()` shell function is gone. Open shells pick up PATH changes —
  including hand edits of `[paths]` — at their next prompt via a prompt hook.
- `[paths]` values are expanded by the shell: `$VAR` / `${VAR}` work, an unset
  variable drops that entry, missing directories are skipped. `[env]` is now
  emitted before PATH so `$GOPATH/bin` works.
- Removing an entry never strips a directory the system PATH also provides.
- The legacy `path.<ext>` is no longer sourced once `[paths]` exists.

**Generation**
- Plain `wayu build` regenerates every initialized shell's files (it used to
  run the turbo export; use `wayu build turbo` for that). Mutations also
  regenerate every initialized shell, not only `$SHELL`'s.
- `wayu config edit` regenerates after the editor exits.
- `wayu build eval` emits code for the shell that evaluates it (its parent
  process), not `$SHELL`; under an unknown shell it prints nothing; as root on
  a user-owned config (`sudo zsh` sourcing your `.zshenv`) it writes nothing.

**Distribution**
- Release binaries: macOS arm64 and Linux x86_64 only. Homebrew refuses other
  architectures with an architecture error.

## 4.4.3

- `$(...)` in `[env]` values is kept literal; it no longer executes at shell
  startup.
- `-f`, `-n`, `-y` after an alias/constant value are kept as part of the value;
  use `--` to end flags explicitly.
- Hook placeholders are passed env-quoted.
- `--dry-run` writes nothing anywhere (no regeneration, no hooks).
- `backup restore` requires `--yes`.
- Exit codes: data errors exit `65`, I/O errors `74`.
- Ctrl+Z no longer suspends the TUI.
