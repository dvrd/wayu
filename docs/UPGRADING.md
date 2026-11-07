# Upgrading wayu

User-visible behavior changes per release. From 4.4.5 on, these are generated
automatically from breaking commits ("⚠ Upgrade notes" in `CHANGELOG.md`);
4.4.3 and 4.4.4 shipped them as patch releases, so they are listed here.

## Unreleased

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
