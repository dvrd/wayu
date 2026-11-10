# Stability guarantees

> **Draft (OKAMI-194)**: proposed for the first stable release; not in
> effect yet. Until then wayu reads only the current format (see the README's
> "Upgrade" section).

What a wayu release promises from the first stable version on, and what
it does not. Version numbers follow [Semantic Versioning](https://semver.org):
anything listed under "Stable" changes only in a major release, and every
such change is listed under "⚠ Upgrade notes" in the release and in
[UPGRADING.md](UPGRADING.md).

## Stable (changes only in a major release)

| Surface | Contract |
|---|---|
| Commands, actions, flags | Everything in [cli.md](cli.md). New commands, actions and flags may be added in a minor release |
| Exit codes | The table in [cli.md](cli.md) "Exit codes" (BSD `sysexits.h` values). A command never starts exiting with a different code for the same situation |
| `--json` output | The shapes in [cli.md](cli.md) "JSON output". Minor releases may add fields; fields are never removed, renamed or retyped |
| `wayu.toml` | Every table and key in [config-reference.md](config-reference.md) keeps its meaning. New keys may be added; an unknown key is a warning, never an error |
| Data files (`entries.json`, `plugins.json`, `secrets.json`) | Each has a `version` field. A release that changes a format reads the previous one and rewrites it once (backup first). Hand edits are supported to the extent [config-reference.md](config-reference.md) documents them |
| Startup line | The one line in your shell rc (`source …/init.<ext>`) keeps working across every release of the same major |
| Data, keys and file locations | When a release moves a file, a directory or a keychain item, it moves it automatically the first time it runs, verifies the result and prints a one-time notice. A manual step is never required |

## Not stable (may change in any release)

- Human-readable output: wording, colors, icons, table layout. Scripts use
  `--json` and exit codes.
- The TUI (`wayu --tui`): layout, keys, views.
- Generated shell code (`core.<ext>`, `path_sync.<ext>`, `turbo.<ext>`,
  plugin loaders) and every file wayu writes in the data dir besides the
  data files above: caches, backups, the lock, `.zwc` digests. Never edit
  them; `wayu build` regenerates them.
- Startup timings and `wayu build profile` output.
- Hidden or internal commands (`completions names`, `--test`/`--snapshot`
  component modes).

## Deprecation

A command, action, flag or config key that is going away:

1. keeps working for at least one minor release, printing a warning on
   stderr that names its replacement, and is marked deprecated in
   [cli.md](cli.md) / [config-reference.md](config-reference.md);
2. is removed only in the next major release, listed in its upgrade notes.

## Supported platforms

Tested on every release (CI) or by the maintainer; see the README's
"Tested with" table. Anything else may work but is not supported.

| | Versions |
|---|---|
| macOS | 15 (CI), 26, 27 |
| Linux | Ubuntu 24.04 (CI) |
| zsh | 5.9 |
| bash | 3.2 (macOS `/bin/bash`), 5.x |
| fish | 4.x |

Dropping a platform or shell version from this table is a major change.
Adding one is a minor change.

## Security fixes

Security fixes ship in a patch release of the latest major only. Report
vulnerabilities privately via GitHub's "Report a vulnerability"
(Security tab), not in public issues.
