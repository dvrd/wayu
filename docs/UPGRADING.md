# Upgrading wayu

User-visible behavior changes per release. From 4.4.5 on, these are generated
automatically from breaking commits ("⚠ Upgrade notes" in `CHANGELOG.md`);
4.4.3 and 4.4.4 shipped them as patch releases, so they are listed here.

## Unreleased

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

**migrate --schema**
- Values it can't convert exactly (multi-line `"""` strings, arrays, inline
  tables) in the rewritten sections are listed as `wayu.toml:N`; nothing is
  written and it exits `65`. They used to be dropped silently (an alias with
  a `"""` command became `""`). A section header with a trailing comment
  (`[aliases] # mine`) is now recognised.
- Waits for other wayu commands (config lock) before rewriting wayu.toml.

**doctor**
- A relative `[paths]` entry (`./node_modules/.bin`) is no longer reported
  as missing or removed by `doctor --fix`: it is counted with the entries
  that "use unset variables or relative paths (left alone)".
- `doctor --fix` exits `78` and changes nothing when a key it would drop is
  repeated in `[paths]` (`a = "/x"` twice); it used to delete every line of
  that key, the kept entry included.

**Backups**
- `wayu backup restore` waits for other wayu commands (config lock) instead
  of racing them; a concurrent edit can no longer overwrite the restore.

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
